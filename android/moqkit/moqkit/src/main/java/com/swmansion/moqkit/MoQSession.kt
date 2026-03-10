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
import uniffi.moq.MoqSession as UniMoqSession
import uniffi.moq.moqConnect
import uniffi.moq.moqOriginCreate

class MoQSession(
    private val url: String,
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
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
        try {
            val newOrigin = moqOriginCreate()
            origin = newOrigin

            val newSession = moqConnect(url, publish = null, consume = newOrigin)
            session = newSession
            _state.value = State.Connected

            // Monitor session lifetime
            monitorJob = scope.launch {
                try {
                    newSession.closed()
                } catch (e: Exception) {
                    _state.compareAndSet(State.Connected, State.Error("Session ended: $e"))
                    close()
                    return@launch
                }
                if (_state.value == State.Connected) {
                    _state.value = State.Error("Session ended unexpectedly")
                    close()
                }
            }

            // Watch announcements
            val announced = newOrigin.announced()
            announcedJob = scope.launch {
                try {
                    while (true) {
                        val info = announced.next() ?: break
                        val path = info.path

                        // Cancel existing broadcast for this path
                        activeBroadcasts.remove(path)?.cancel()

                        if (info.active) {
                            val broadcast = newOrigin.consume(path)
                            val job = scope.launch { watchCatalog(path, broadcast) }
                            activeBroadcasts[path] = job
                        } else {
                            _broadcasts.emit(MoQBroadcastEvent.Unavailable(path))
                        }
                    }
                } catch (_: Exception) {
                    // announced stream ended
                }
            }
        } catch (e: Exception) {
            _state.value = State.Error(e.message ?: "Connection failed")
            tearDown()
            throw e
        }
    }

    private suspend fun watchCatalog(path: String, broadcast: MoqBroadcast) {
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
                _broadcasts.emit(MoQBroadcastEvent.Available(MoQBroadcastInfo(path, videoTracks, audioTracks)))
            }
        } finally {
            catalogStream.close()
        }
    }

    suspend fun close() {
        val wasConnected = _state.compareAndSet(State.Connected, State.Closed)
        val wasConnecting = if (!wasConnected) _state.compareAndSet(State.Connecting, State.Closed) else false
        val wasError = if (!wasConnected && !wasConnecting) {
            val current = _state.value
            if (current is State.Error) _state.compareAndSet(current, State.Closed) else false
        } else false

        if (!wasConnected && !wasConnecting && !wasError) return
        tearDown()
    }

    private suspend fun tearDown() {
        for ((_, job) in activeBroadcasts) { job.cancel() }
        activeBroadcasts.clear()
        monitorJob?.cancel()
        announcedJob?.cancel()
        session?.disconnect()
        session?.close()
        scope.cancel()
        session = null
        origin = null
    }
}
