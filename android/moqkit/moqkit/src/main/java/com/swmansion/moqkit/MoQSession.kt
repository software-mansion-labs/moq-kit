package com.swmansion.moqkit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
import uniffi.moq.MoqSession as UniMoqSession

class MoQSession(
    private val url: String,
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    companion object {
        private const val TAG = "MoQSession"
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    sealed class State {
        object Idle : State()
        object Connecting : State()
        object Connected : State()
        data class Error(val message: String) : State()
        object Closed : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _broadcasts = MutableSharedFlow<MoQBroadcastEvent>(replay = 1)
    val broadcasts: SharedFlow<MoQBroadcastEvent> = _broadcasts

    private var session: UniMoqSession? = null
    private var client: MoqClient? = null
    private var origin: MoqOriginProducer? = null
    private var consumer: MoqOriginConsumer? = null
    private var announced: MoqAnnounced? = null
    private var monitorJob: Job? = null
    private var announcedJob: Job? = null

    // Per-path broadcast state: path -> catalogWatchJob
    private val activeBroadcasts = mutableMapOf<String, Job>()
    private val catalogConsumers = mutableMapOf<String, MoqCatalogConsumer>()

    suspend fun connect() {
        check(_state.value == State.Idle) { "Session already started" }
        _state.value = State.Connecting
        Log.d(TAG, "Connecting to $url")
        try {
            val newOrigin = MoqOriginProducer()
            origin = newOrigin
            Log.d(TAG, "Origin created")

            val newClient = MoqClient()
            client = newClient
            newClient.setConsume(newOrigin)

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
        try {
            catalogConsumer = broadcast.subscribeCatalog()
            catalogConsumers[path] = catalogConsumer
            while (true) {
                val catalog = catalogConsumer.next() ?: break
                val videoTracks = catalog.video.map { (name, rendition) ->
                    MoQVideoTrackInfo(name = name, config = rendition, broadcast = broadcast)
                }
                val audioTracks = catalog.audio.map { (name, rendition) ->
                    MoQAudioTrackInfo(name = name, config = rendition, broadcast = broadcast)
                }
                Log.d(TAG, "Catalog update for '$path': ${videoTracks.size} video, ${audioTracks.size} audio tracks")
                for (v in videoTracks) {
                    Log.d(TAG, "  Video track '${v.name}': codec=${v.config.codec} container=${v.config.container} ${v.config.coded?.width}x${v.config.coded?.height}")
                }
                for (a in audioTracks) {
                    Log.d(TAG, "  Audio track '${a.name}': codec=${a.config.codec} container=${a.config.container} ${a.config.sampleRate}Hz ${a.config.channelCount}ch")
                }
                _broadcasts.emit(MoQBroadcastEvent.Available(MoQBroadcastInfo(path, videoTracks, audioTracks)))
            }
            Log.d(TAG, "Catalog stream ended for '$path'")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to watch catalog for '$path': $e")
        } finally {
            // Only clean up if we still own the consumer (tearDown may have already taken it)
            if (catalogConsumers.remove(path) != null) {
                try {
                    catalogConsumer?.cancel()
                    catalogConsumer?.close()
                } catch (_: IllegalStateException) {
                    // Already destroyed by tearDown
                }
            }
            _broadcasts.emit(MoQBroadcastEvent.Unavailable(path))
        }
    }

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

        origin?.close()
        origin = null

        scope.cancel()
        Log.d(TAG, "Teardown complete")
    }
}
