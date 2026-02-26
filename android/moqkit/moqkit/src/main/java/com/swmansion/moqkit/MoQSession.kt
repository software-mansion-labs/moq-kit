@file:OptIn(UnstableApi::class) package com.swmansion.moqkit

import android.content.Context
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.Format
import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
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
    parentScope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
) {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    sealed class State {
        object Idle : State()
        object Connecting : State()
        object Connected : State()
        object Playing : State()
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

    private var player: ExoPlayer? = null
    private var activeCatalog: MoQCatalog? = null
    private var pendingCatalog: MoQCatalog? = null

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
            pendingCatalog?.close()   // superseded by new catalog, never activated — safe to close
            pendingCatalog = catalog
            val videoTracks = buildList {
                var i = 0u
                while (true) {
                    try { add(IndexedValue(i.toInt(), catalog.videoConfig(i++))) }
                    catch (_: MoqException) { break }
                }
            }
            val audioTracks = buildList {
                var i = 0u
                while (true) {
                    try { add(IndexedValue(i.toInt(), catalog.audioConfig(i++))) }
                    catch (_: MoqException) { break }
                }
            }
            _broadcasts.emit(BroadcastInfo(broadcastHandle, videoTracks, audioTracks))
        }
        // No finally: tearDown owns pendingCatalog cleanup. A finally would race with
        // startTrack activating pendingCatalog or with tearDown closing it.
    }

    fun subscribeVideo(broadcastHandle: UInt, index: UInt): Flow<FrameData> =
        subscribeVideoTrack(broadcastHandle, index, maxLatencyMs)

    fun subscribeAudio(broadcastHandle: UInt, index: UInt): Flow<FrameData> =
        subscribeAudioTrack(broadcastHandle, index, maxLatencyMs)

    suspend fun startTrack(
        context: Context,
        videoIndex: UInt? = null,
        audioIndex: UInt? = null,
    ): ExoPlayer? {
        val info = _broadcasts.replayCache.firstOrNull() ?: return null
        tearDownTracks()

        if (pendingCatalog != null) {
            activeCatalog?.close()
            activeCatalog = pendingCatalog
            pendingCatalog = null
        }

        val videoConfig = videoIndex?.let { info.videoTracks.getOrNull(it.toInt())?.value }
        val audioConfig = audioIndex?.let { info.audioTracks.getOrNull(it.toInt())?.value }

        val videoFormat = videoConfig?.let { MediaFactory.makeVideoFormatMedia3(it) }
        val audioFormat = audioConfig?.let { MediaFactory.makeAudioFormatMedia3(it) }

        Log.i("MOQ", "videoIndex = $videoIndex, audioIndex = $audioIndex")
        Log.i("MOQ", "videoFormat = $videoFormat")
        Log.i("MOQ", "audioFormat = $audioFormat")
        val videoFlow = videoIndex?.let { subscribeVideo(info.broadcastHandle, it) }
        val audioFlow = audioIndex?.let { subscribeAudio(info.broadcastHandle, it) }

        val source = MoQMediaSource(videoFormat, audioFormat, videoFlow, audioFlow, scope)
        val newPlayer = ExoPlayer.Builder(context).build()

        newPlayer.setTrackSelectionParameters(
            newPlayer.getTrackSelectionParameters()
                .buildUpon()
                // This won't remove the keys, but sets them to neutral
                .build()
        );

        newPlayer.addListener(object : Player.Listener {
            override fun onTracksChanged(tracks: Tracks) {
                Log.i("Exo", tracks.toString())
                for (group in tracks.groups) {
                    if (group.type == C.TRACK_TYPE_AUDIO) {
                        // Is the track supported by the hardware?
                        val isSupported = group.isSupported
                        // Is the player actually trying to play it?
                        val isSelected = group.isSelected

                        Log.i("ExoPlayer", "Audio Group: Supported=$isSupported, Selected=$isSelected")
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e("Exo", "Player error: ${error.errorCodeName} cause=${error.cause}", error)
                _state.value = State.Error(error.errorCode)
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                Log.i("Exo", "Player state change $playbackState")
                if (playbackState == Player.STATE_READY) {
                    _state.compareAndSet(State.Connected, State.Playing)
                }
            }
        })

        newPlayer.addAnalyticsListener(object : AnalyticsListener {
            override fun onAudioInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                eval: DecoderReuseEvaluation?
            ) {
                Log.i("Exo", "Audio format: $format")
            }

            override fun onAudioDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long
            ) {
                Log.i("Exo", "Audio decoder: $decoderName init=${initializationDurationMs}ms")
            }

            override fun onAudioUnderrun(
                eventTime: AnalyticsListener.EventTime,
                bufferSize: Int,
                bufferSizeMs: Long,
                elapsedSinceLastFeedMs: Long
            ) {
                Log.w("Exo", "Audio underrun bufferSize=$bufferSize sizeMs=$bufferSizeMs")
            }

            override fun onAudioSinkError(eventTime: AnalyticsListener.EventTime, audioSinkError: Exception) {
                Log.e("Exo", "Audio sink error", audioSinkError)
            }

            override fun onAudioCodecError(eventTime: AnalyticsListener.EventTime, audioCodecError: Exception) {
                Log.e("Exo", "Audio codec error", audioCodecError)
            }
        })

        newPlayer.setMediaSource(source)
        newPlayer.prepare()
        newPlayer.play()
        player = newPlayer

        return newPlayer
    }

    suspend fun close() {
        val wasConnected = _state.compareAndSet(State.Connected, State.Closed)
        val wasConnecting = if (!wasConnected) _state.compareAndSet(State.Connecting, State.Closed) else false
        val wasPlaying = if (!wasConnected && !wasConnecting) _state.compareAndSet(State.Playing, State.Closed) else false
        val wasError = if (!wasConnected && !wasConnecting && !wasPlaying) {
            val current = _state.value
            if (current is State.Error) _state.compareAndSet(current, State.Closed) else false
        } else false

        if (!wasConnected && !wasConnecting && !wasPlaying && !wasError) return
        tearDown()
    }

    private fun tearDownTracks() {
        player?.stop()
        player?.release()
        player = null
        if (_state.value == State.Playing) _state.value = State.Connected
    }

    private suspend fun tearDown() {
        tearDownTracks()
        activeCatalog?.close()
        activeCatalog = null
        pendingCatalog?.close()
        pendingCatalog = null
        monitorJob?.cancel()
        transport?.close()
        origin?.close()
        scope.cancel()
        transport = null
        origin = null
    }
}
