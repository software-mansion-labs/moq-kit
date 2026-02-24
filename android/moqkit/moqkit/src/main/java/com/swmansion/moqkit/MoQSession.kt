package com.swmansion.moqkit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import uniffi.moq.AudioConfig
import uniffi.moq.FrameData
import uniffi.moq.MoqException
import uniffi.moq.VideoConfig

class MoQSession(
    private val url: String,
    private val path: String,
    private val maxLatencyMs: ULong = 1000u,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    sealed class State {
        object Idle : State()
        object Connecting : State()
        object Connected : State()
        data class Error(val code: Int) : State()
        object Closed : State()
    }

    data class BroadcastInfo(
        val broadcastHandle: UInt,
        val videoTracks: List<IndexedValue<VideoConfig>>,
        val audioTracks: List<IndexedValue<AudioConfig>>,
    )

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _broadcasts = MutableSharedFlow<BroadcastInfo>(replay = 1)
    val broadcasts: SharedFlow<BroadcastInfo> = _broadcasts

    private var transport: MoQTransport? = null
    private var origin: MoQOrigin? = null
    private var monitorJob: Job? = null

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
                newOrigin.announced()
                    .filter { it.path == path && it.active }
                    .collect { info ->
                        val broadcastHandle = newOrigin.consume(info.path)
                        scope.launch { watchCatalog(broadcastHandle) }
                    }
            }
        } catch (e: Exception) {
            _state.value = State.Error(-1)
            tearDown()
            throw e
        }
    }

    private suspend fun watchCatalog(broadcastHandle: UInt) {
        subscribeCatalog(broadcastHandle).collect { catalog ->
            catalog.use { c ->
                val videoTracks = buildList {
                    var i = 0u
                    while (true) {
                        try { add(IndexedValue(i.toInt(), c.videoConfig(i++))) }
                        catch (_: MoqException) { break }
                    }
                }
                val audioTracks = buildList {
                    var i = 0u
                    while (true) {
                        try { add(IndexedValue(i.toInt(), c.audioConfig(i++))) }
                        catch (_: MoqException) { break }
                    }
                }
                _broadcasts.emit(BroadcastInfo(broadcastHandle, videoTracks, audioTracks))
            }
        }
    }

    fun subscribeVideo(broadcastHandle: UInt, index: UInt): Flow<FrameData> =
        subscribeVideoTrack(broadcastHandle, index, maxLatencyMs)

    fun subscribeAudio(broadcastHandle: UInt, index: UInt): Flow<FrameData> =
        subscribeAudioTrack(broadcastHandle, index, maxLatencyMs)

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
        monitorJob?.cancel()
        transport?.close()
        origin?.close()
        scope.cancel()
        transport = null
        origin = null
    }
}
