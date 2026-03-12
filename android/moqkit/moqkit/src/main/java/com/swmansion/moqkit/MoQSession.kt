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
import uniffi.moq.MoqBroadcast
import uniffi.moq.MoqOrigin
import android.util.Log
import uniffi.moq.MoqSession as UniMoqSession
import uniffi.moq.moqConnect
import uniffi.moq.moqOriginCreate

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
    private var origin: MoqOrigin? = null
    private var monitorJob: Job? = null
    private var announcedJob: Job? = null

    // Per-path broadcast state: path → catalogWatchJob
    private val activeBroadcasts = mutableMapOf<String, Job>()

    suspend fun connect() {
        check(_state.value == State.Idle) { "Session already started" }
        _state.value = State.Connecting
        Log.d(TAG, "Connecting to $url")
        try {
            val newOrigin = moqOriginCreate()
            origin = newOrigin
            Log.d(TAG, "Origin created")

            val newSession = moqConnect(url, publish = null, consume = newOrigin)
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
            val announced = newOrigin.announced()
            announcedJob = scope.launch {
                Log.d(TAG, "Watching for announcements")
                try {
                    while (true) {
                        val info = announced.next() ?: break
                        val path = info.path
                        Log.d(TAG, "Announcement: path='$path' active=${info.active}")

                        // Cancel existing broadcast for this path
                        activeBroadcasts.remove(path)?.let {
                            Log.d(TAG, "Cancelling previous broadcast for '$path'")
                            it.cancel()
                        }

                        if (info.active) {
                            val broadcast = newOrigin.consume(path)
                            val job = scope.launch { watchCatalog(path, broadcast) }
                            activeBroadcasts[path] = job
                        } else {
                            _broadcasts.emit(MoQBroadcastEvent.Unavailable(path))
                        }
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

    private suspend fun watchCatalog(path: String, broadcast: MoqBroadcast) {
        Log.d(TAG, "Watching catalog for '$path'")
        try {
            val catalogStream = broadcast.catalog()
            try {
                while (true) {
                    val catalog = catalogStream.next() ?: break
                    val videoTracks = catalog.video.map { (name, rendition) ->
                        MoQVideoTrackInfo(name = name, config = rendition, broadcast = broadcast)
                    }
                    val audioTracks = catalog.audio.map { (name, rendition) ->
                        MoQAudioTrackInfo(name = name, config = rendition, broadcast = broadcast)
                    }
                    Log.d(TAG, "Catalog update for '$path': ${videoTracks.size} video, ${audioTracks.size} audio tracks")
                    for (v in videoTracks) {
                        Log.d(TAG, "  Video track '${v.name}': codec=${v.config.codec} ${v.config.codedWidth}x${v.config.codedHeight}")
                    }
                    for (a in audioTracks) {
                        Log.d(TAG, "  Audio track '${a.name}': codec=${a.config.codec} ${a.config.sampleRate}Hz ${a.config.channelCount}ch")
                    }
                    _broadcasts.emit(MoQBroadcastEvent.Available(MoQBroadcastInfo(path, videoTracks, audioTracks)))
                }
                Log.d(TAG, "Catalog stream ended for '$path'")
            } finally {
                catalogStream.close()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to watch catalog for '$path': $e")
            _broadcasts.emit(MoQBroadcastEvent.Unavailable(path))
        }
    }

    suspend fun close() {
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

    private suspend fun tearDown() {
        Log.d(TAG, "Tearing down: ${activeBroadcasts.size} active broadcasts")
        for ((path, job) in activeBroadcasts) {
            Log.d(TAG, "Cancelling broadcast '$path'")
            job.cancel()
        }
        activeBroadcasts.clear()
        monitorJob?.cancel()
        announcedJob?.cancel()
        session?.disconnect()
        session?.close()
        scope.cancel()
        session = null
        origin = null
        Log.d(TAG, "Teardown complete")
    }
}
