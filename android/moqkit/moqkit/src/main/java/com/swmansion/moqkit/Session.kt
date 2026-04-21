package com.swmansion.moqkit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.moq.MoqAnnounced
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqCatalogConsumer
import uniffi.moq.MoqClient
import uniffi.moq.MoqOriginConsumer
import uniffi.moq.MoqOriginProducer
import android.util.Log
import com.swmansion.moqkit.publish.Publisher
import com.swmansion.moqkit.subscribe.AudioTrackInfo
import com.swmansion.moqkit.subscribe.BroadcastEvent
import com.swmansion.moqkit.subscribe.BroadcastInfo
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import uniffi.moq.MoqSession as UniMoqSession

/**
 * A QUIC connection to a MOQ relay that discovers and surfaces live broadcasts.
 *
 * ### Lifecycle
 * 1. Create a session with the relay [url].
 * 2. Call [connect] (suspend) — it returns once the QUIC handshake completes and
 *    announcement watching begins.
 * 3. Collect [broadcasts] to receive [BroadcastEvent.Available] / [BroadcastEvent.Unavailable]
 *    events as publishers come and go.
 * 4. Call [close] to tear down the connection and free all resources.
 *
 * @param url WebTransport URL of the MOQ relay (e.g. `"https://relay.example.com:4443/moq"`).
 * @param parentScope Coroutine scope whose lifetime bounds the session. Defaults to a new
 *   IO-dispatched scope with a [SupervisorJob].
 */
class Session(
    private val url: String,
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    companion object {
        private const val TAG = "Session"
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())

    /** Connection state machine for this session. */
    sealed class State {
        /** Session has not been started yet. */
        object Idle : State()
        /** QUIC handshake is in progress. */
        object Connecting : State()
        /** Handshake complete; broadcasts are being watched. */
        object Connected : State()
        /** The session ended due to a transport or protocol error.
         * @property message Human-readable error description. */
        data class Error(val message: String) : State()
        /** [Session.close] was called and all resources have been released. */
        object Closed : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)

    /**
     * Current connection state. Starts at [State.Idle] and progresses through
     * [State.Connecting] → [State.Connected] → [State.Closed] (or [State.Error]).
     */
    val state: StateFlow<State> = _state.asStateFlow()

    private val _broadcasts = MutableSharedFlow<BroadcastEvent>(replay = 1)

    /**
     * Stream of broadcast lifecycle events emitted as publishers announce or retract broadcasts.
     *
     * The flow replays the most recent event so late collectors receive the current snapshot
     * immediately. Collect this flow after [connect] returns to be notified of available tracks.
     */
    val broadcasts: SharedFlow<BroadcastEvent> = _broadcasts

    private var session: UniMoqSession? = null
    private var client: MoqClient? = null
    private var origin: MoqOriginProducer? = null
    private var publishOrigin: MoqOriginProducer? = null
    private var consumer: MoqOriginConsumer? = null
    private var announced: MoqAnnounced? = null
    private var monitorJob: Job? = null
    private var announcedJob: Job? = null

    // Per-path broadcast state: path -> catalogWatchJob
    private val activeBroadcasts = mutableMapOf<String, Job>()
    private val catalogConsumers = mutableMapOf<String, MoqCatalogConsumer>()
    private val activePublishers = mutableMapOf<String, Publisher>()

    /**
     * Opens the QUIC connection and begins watching for broadcast announcements.
     *
     * Suspends until the handshake is complete. Once this function returns, [state] is
     * [State.Connected] and [broadcasts] will start emitting events.
     *
     * @throws IllegalStateException if called on a session that has already been started.
     * @throws Exception if the connection attempt fails (state becomes [State.Error]).
     */
    suspend fun connect() {
        check(_state.value == State.Idle) { "Session already started" }
        _state.value = State.Connecting
        Log.d(TAG, "Connecting to $url")
        try {
            val newOrigin = MoqOriginProducer()
            origin = newOrigin
            Log.d(TAG, "Origin created")

            val newPublishOrigin = MoqOriginProducer()
            publishOrigin = newPublishOrigin

            val newClient = MoqClient()
            newClient.setTlsDisableVerify(true)
            client = newClient
            newClient.setConsume(newOrigin)
            newClient.setPublish(newPublishOrigin)

            val newSession = newClient.connect(url)
            session = newSession
            _state.value = State.Connected
            Log.d(TAG, "Connected successfully")

            // Monitor session lifetime
            monitorJob = scope.launch {
                try {
                    newSession.closed()
                } catch (e: Exception) {
                    Log.w(TAG, "Session closed with error: $e")
                    _state.compareAndSet(State.Connected, State.Error("Session ended: $e"))
                    close()
                    return@launch
                }
                if (_state.value == State.Connected) {
                    Log.w(TAG, "Session ended unexpectedly")
                    _state.value = State.Error("Session ended unexpectedly")
                    close()
                }
            }

            // Watch announcements
            val newConsumer = newOrigin.consume()
            consumer = newConsumer
            val newAnnounced = newConsumer.announced("")
            announced = newAnnounced

            announcedJob = scope.launch {
                Log.d(TAG, "Watching for announcements")
                try {
                    while (true) {
                        val announcement = newAnnounced.next() ?: break
                        val path = announcement.path()
                        Log.d(TAG, "Announcement: path='$path'")

                        // Cancel existing broadcast for this path
                        activeBroadcasts.remove(path)?.let {
                            Log.d(TAG, "Cancelling previous broadcast for '$path'")
                            it.cancel()
                        }
                        catalogConsumers.remove(path)?.let {
                            it.cancel()
                            it.close()
                        }

                        val broadcast = announcement.broadcast()
                        val job = scope.launch { watchCatalog(path, broadcast) }
                        activeBroadcasts[path] = job
                    }
                    Log.d(TAG, "Announcement stream ended")
                } catch (e: Exception) {
                    Log.d(TAG, "Announcement stream ended with error: $e")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Connection failed: ${e.message}", e)
            _state.value = State.Error(e.message ?: "Connection failed")
            tearDown()
            throw e
        }
    }

    private suspend fun watchCatalog(path: String, broadcast: MoqBroadcastConsumer) {
        Log.d(TAG, "Watching catalog for '$path'")
        var catalogConsumer: MoqCatalogConsumer? = null
        val currentJob = currentCoroutineContext()[Job]
        try {
            catalogConsumer = broadcast.subscribeCatalog()
            catalogConsumers[path] = catalogConsumer
            while (true) {
                val catalog = catalogConsumer.next() ?: break
                val videoTracks = catalog.video.map { (name, rendition) ->
                    VideoTrackInfo(name = name, config = rendition, broadcast = broadcast)
                }
                val audioTracks = catalog.audio.map { (name, rendition) ->
                    AudioTrackInfo(name = name, config = rendition, broadcast = broadcast)
                }
                Log.d(TAG, "Catalog update for '$path': ${videoTracks.size} video, ${audioTracks.size} audio tracks")
                for (v in videoTracks) {
                    Log.d(TAG, "  Video track '${v.name}': codec=${v.config.codec} container=${v.config.container} ${v.config.coded?.width}x${v.config.coded?.height}")
                }
                for (a in audioTracks) {
                    Log.d(TAG, "  Audio track '${a.name}': codec=${a.config.codec} container=${a.config.container} ${a.config.sampleRate}Hz ${a.config.channelCount}ch")
                }
                _broadcasts.emit(BroadcastEvent.Available(BroadcastInfo(path, videoTracks, audioTracks)))
            }
            Log.d(TAG, "Catalog stream ended for '$path'")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to watch catalog for '$path': $e")
        } finally {
            val trackedConsumer = catalogConsumers[path]
            if (trackedConsumer === catalogConsumer) {
                catalogConsumers.remove(path)
            }
            if (trackedConsumer === catalogConsumer || trackedConsumer == null) {
                try {
                    catalogConsumer?.cancel()
                    catalogConsumer?.close()
                } catch (_: IllegalStateException) {
                    // Already destroyed by tearDown
                }
            }

            if (activeBroadcasts[path] === currentJob) {
                activeBroadcasts.remove(path)
                _broadcasts.emit(BroadcastEvent.Unavailable(path))
            }
        }
    }

    /**
     * Publish a broadcast to the relay at the given path.
     *
     * The publisher's broadcast is registered with the relay. Call [Publisher.start] after
     * this to begin encoding and sending frames.
     *
     * @param path Broadcast path on the relay (e.g. `"live/my-stream"`).
     * @param publisher A configured [Publisher] with at least one track added.
     * @throws IllegalStateException if the session is not connected.
     */
    fun publish(path: String, publisher: Publisher) {
        check(_state.value == State.Connected) { "Session must be connected before publishing" }
        check(!activePublishers.containsKey(path)) { "Already publishing at '$path'. Call unpublish() first." }
        val po = publishOrigin ?: error("Publish origin not available")
        Log.d(TAG, "Publishing broadcast at '$path'")
        po.publish(path, publisher.broadcast)
        activePublishers[path] = publisher
    }

    /**
     * Stop publishing at the given path. Calls [Publisher.stop] on the associated publisher.
     */
    fun unpublish(path: String) {
        val publisher = activePublishers.remove(path) ?: return
        Log.d(TAG, "Unpublishing broadcast at '$path'")
        publisher.stop()
    }

    /**
     * Closes the session and releases all resources.
     *
     * Safe to call from any thread. No-op if the session is already [State.Closed].
     * After this returns, [state] is [State.Closed] and the coroutine scope is cancelled.
     */
    fun close() {
        val wasConnected = _state.compareAndSet(State.Connected, State.Closed)
        val wasConnecting = if (!wasConnected) _state.compareAndSet(State.Connecting, State.Closed) else false
        val wasError = if (!wasConnected && !wasConnecting) {
            val current = _state.value
            if (current is State.Error) _state.compareAndSet(current, State.Closed) else false
        } else false

        if (!wasConnected && !wasConnecting && !wasError) {
            Log.d(TAG, "close() called but already in state ${_state.value}")
            return
        }
        Log.d(TAG, "Closing session (was: connected=$wasConnected connecting=$wasConnecting error=$wasError)")
        tearDown()
    }

    private fun tearDown() {
        Log.d(TAG, "Tearing down: ${activeBroadcasts.size} active broadcasts")

        // Cancel per-broadcast jobs and catalog consumers
        // Snapshot and clear maps first so coroutine finally blocks see empty maps
        val jobs = activeBroadcasts.values.toList()
        activeBroadcasts.clear()
        val catalogs = catalogConsumers.values.toList()
        catalogConsumers.clear()
        jobs.forEach { it.cancel() }
        catalogs.forEach { it.cancel(); it.close() }

        // Stop active publishers
        activePublishers.values.forEach { it.stop() }
        activePublishers.clear()

        // Cancel background jobs
        monitorJob?.cancel()
        announcedJob?.cancel()

        // Cancel and close UniFFI objects (reverse creation order)
        announced?.cancel()
        announced?.close()
        announced = null

        consumer?.close()
        consumer = null

        session?.cancel(0u)
        session?.close()
        session = null

        client?.cancel()
        client?.close()
        client = null

        publishOrigin?.close()
        publishOrigin = null

        origin?.close()
        origin = null

        scope.cancel()
        Log.d(TAG, "Teardown complete")
    }
}
