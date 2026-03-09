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
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import uniffi.moq.MoqException

class MoQSession(
    private val url: String,
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    sealed class State {
        object Idle : State()
        object Connecting : State()
        object Connected : State()
        data class Error(val code: Int) : State()
        object Closed : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _broadcasts = MutableSharedFlow<MoQBroadcastEvent>(replay = 1)
    val broadcasts: SharedFlow<MoQBroadcastEvent> = _broadcasts

    private var transport: MoQTransport? = null
    private var origin: MoQOrigin? = null
    private var monitorJob: Job? = null

    // Per-path broadcast state: path → (broadcastHandle, catalogWatchJob)
    private val activeBroadcasts = mutableMapOf<String, Pair<UInt, Job>>()

    suspend fun connect() {
        check(_state.value == State.Idle) { "Session already started" }
        _state.value = State.Connecting
        try {
            val newOrigin = MoQOrigin()
            origin = newOrigin

            val newTransport = MoQTransport.connect(url = url, consumeOrigin = newOrigin.handle)
            transport = newTransport
            _state.value = State.Connected

            monitorJob = scope.launch {
                newTransport.statusFlow
                    .filter { it != 0 }
                    .firstOrNull()
                    ?.let { code -> _state.compareAndSet(State.Connected, State.Error(code)) }
            }

            scope.launch {
                newOrigin.announced().collect { info ->
                    val path = info.path

                    // Cancel existing broadcast for this path
                    activeBroadcasts.remove(path)?.second?.cancel()

                    if (info.active) {
                        val broadcastHandle = newOrigin.consume(path)
                        val job = scope.launch { watchCatalog(path, broadcastHandle) }
                        activeBroadcasts[path] = Pair(broadcastHandle, job)
                    } else {
                        _broadcasts.emit(MoQBroadcastEvent.Unavailable(path))
                    }
                }
            }
        } catch (e: Exception) {
            _state.value = State.Error(-1)
            tearDown()
            throw e
        }
    }

    private suspend fun watchCatalog(path: String, broadcastHandle: UInt) {
        subscribeCatalog(broadcastHandle).collect { catalog ->
            val videoTracks = buildList {
                var i = 0u
                while (true) {
                    try { add(MoQVideoTrackInfo(i, catalog.videoConfig(i++), catalog)) }
                    catch (_: MoqException) { break }
                }
            }
            val audioTracks = buildList {
                var i = 0u
                while (true) {
                    try { add(MoQAudioTrackInfo(i, catalog.audioConfig(i++), catalog)) }
                    catch (_: MoqException) { break }
                }
            }
            _broadcasts.emit(MoQBroadcastEvent.Available(MoQBroadcastInfo(path, videoTracks, audioTracks)))
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
        for ((_, entry) in activeBroadcasts) { entry.second.cancel() }
        activeBroadcasts.clear()
        monitorJob?.cancel()
        transport?.close()
        origin?.close()
        scope.cancel()
        transport = null
        origin = null
    }
}
