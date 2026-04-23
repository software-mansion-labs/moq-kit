package com.swmansion.moqkit.subscribe

import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.subscribe.internal.subscribeTrack
import com.swmansion.moqkit.subscribe.internal.playback.AudioRenderer
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackMetricsAccumulator
import com.swmansion.moqkit.subscribe.internal.playback.VideoRenderer
import com.swmansion.moqkit.subscribe.internal.playback.VideoRendererTrack
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch

private const val TAG = "Player"

/**
 * Real-time audio+video player with fine-grained latency control.
 *
 * Uses MediaCodec (async) for decoding, AudioTrack (MODE_STREAM) for audio output,
 * and a Surface-configured MediaCodec for video output — bypassing ExoPlayer for lower latency.
 *
 * ### Typical usage
 * ```kotlin
 * val player = Player(
 *     catalog = catalog,
 *     videoTrackName = catalog.videoTracks.firstOrNull()?.name,
 *     audioTrackName = catalog.audioTracks.firstOrNull()?.name,
 *     targetLatencyMs = 150,
 *     parentScope = lifecycleScope,
 * )
 * player.setSurface(surfaceView.holder.surface)
 * player.play()
 * // … later …
 * player.close()
 * ```
 *
 * @param catalog The catalog that describes the tracks available in the broadcast.
 * @param videoTrackName The selected video track name from [Catalog.videoTracks], or `null`
 *   to disable video playback. Unknown names throw [IllegalArgumentException].
 * @param audioTrackName The selected audio track name from [Catalog.audioTracks], or `null`
 *   to disable audio playback. Unknown names throw [IllegalArgumentException].
 * @param targetLatencyMs Target end-to-end playback latency in milliseconds. Lower values
 *   reduce delay at the cost of increased risk of stalls. Defaults to 100 ms.
 * @param parentScope Coroutine scope whose lifetime bounds the player's internal coroutines.
 */
class Player(
    private val catalog: Catalog,
    videoTrackName: String? = null,
    audioTrackName: String? = null,
    targetLatencyMs: Int = 100,
    parentScope: CoroutineScope,
) : AutoCloseable {
    /**
     * Playback lifecycle events emitted by the player.
     */
    sealed class Event {
        /** A track started producing decoded output. [kind] is `"audio"` or `"video"`. */
        data class TrackPlaying(val kind: String) : Event()
        /** A track was paused via [pause]. [kind] is `"audio"` or `"video"`. */
        data class TrackPaused(val kind: String) : Event()
        /** A track's incoming data stream ended. [kind] is `"audio"` or `"video"`. */
        data class TrackStopped(val kind: String) : Event()
        /** An unrecoverable error occurred on a track. */
        data class Error(val kind: String, val message: String) : Event()
        /** All active tracks have stopped (stream ended or [stop] called). */
        object AllTracksStopped : Event()
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    private val accumulator = PlaybackMetricsAccumulator()

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 8)
    val events: SharedFlow<Event> = _events

    private val broadcastOwner: BroadcastOwner
    private var selectedVideoTrack: VideoTrackInfo?
    private var selectedAudioTrack: AudioTrackInfo?
    private var targetLatencyMs = targetLatencyMs

    private var audioRenderer: AudioRenderer? = null
    private var videoRenderer: VideoRenderer? = null
    private var audioIngestJob: Job? = null
    private var videoIngestJob: Job? = null
    private var surface: Surface? = null
    private var playing = false
    private var closed = false

    init {
        val resolvedVideoTrack = resolveVideoTrack(videoTrackName)
        val resolvedAudioTrack = resolveAudioTrack(audioTrackName)
        check(resolvedVideoTrack != null || resolvedAudioTrack != null) {
            "at least one audio or video track is expected"
        }
        selectedVideoTrack = resolvedVideoTrack
        selectedAudioTrack = resolvedAudioTrack
        broadcastOwner = catalog.retainBroadcastOwner()
    }

    /** Current playback time in microseconds. */
    val currentTimeUs: Long
        get() = audioRenderer?.currentTimeUs ?: 0L

    /** Snapshot of current playback metrics. */
    val stats: PlaybackStats
        get() {
            val timeUs = audioRenderer?.currentTimeUs ?: 0L
            val audioLatency = audioRenderer?.let {
                if (it.lastIngestPtsUs > 0 && timeUs > 0) {
                    (it.lastIngestPtsUs - timeUs).toDouble() / 1000.0
                } else {
                    null
                }
            }
            val videoLatency = videoRenderer?.let {
                if (it.lastIngestPtsUs > 0 && timeUs > 0) {
                    (it.lastIngestPtsUs - timeUs).toDouble() / 1000.0
                } else {
                    null
                }
            }
            return accumulator.snapshot(
                audioLatencyMs = if (selectedAudioTrack != null) audioLatency else null,
                videoLatencyMs = if (selectedVideoTrack != null) videoLatency else null,
                audioRingBufferMs = if (selectedAudioTrack != null) audioRenderer?.bufferFillMs else null,
                videoJitterBufferMs = if (selectedVideoTrack != null) videoRenderer?.bufferFillMs else null,
            )
        }

    /**
     * Set, swap, or clear the video output surface.
     * If [play] was already called and a surface becomes available, starts the video pipeline.
     * If a different surface is provided while video is running, attempts an in-place swap and
     * falls back to restarting video on the new surface if the codec rejects the change.
     * If surface becomes null, stops the active video renderer.
     */
    fun setSurface(surface: Surface?) {
        val previousSurface = this.surface
        this.surface = surface

        when {
            surface == null -> {
                if (videoRenderer != null) {
                    stopVideo()
                }
            }

            videoRenderer == null -> {
                if (playing && selectedVideoTrack != null) {
                    startVideo(surface)
                }
            }

            previousSurface !== surface -> swapVideoSurface(surface)
        }
    }

    /**
     * Starts audio (and video, if a surface is set) playback.
     *
     * Safe to call if a surface has not yet been provided — video will start automatically
     * once [setSurface] is called. The first decoded audio or video frame triggers an
     * [Event.TrackPlaying] event for that media kind.
     */
    fun play() {
        check(!closed) { "Player is already closed" }
        if (playing) {
            return
        }

        playing = true
        accumulator.markPlayStart()
        startAudio()
        surface?.let { startVideo(it) }
    }

    /**
     * Switches to a different video rendition.
     *
     * Passing `null` disables video playback. If that would leave both media kinds disabled,
     * this call throws.
     */
    fun switchTrack(trackName: String?) {
        check(!closed) { "Player is already closed" }
        val newTrack = resolveVideoTrack(trackName)
        if (newTrack?.name == selectedVideoTrack?.name) {
            return
        }
        check(newTrack != null || selectedAudioTrack != null) {
            "at least one audio or video track is expected"
        }

        val currentTrack = selectedVideoTrack
        selectedVideoTrack = newTrack

        if (!playing) {
            return
        }

        val renderer = videoRenderer
        if (currentTrack != null && newTrack != null && renderer != null && !renderer.hasPendingTrack) {
            switchActiveVideoTrack(newTrack, renderer)
            return
        }

        restartPlaybackForSelectionChange()
    }

    /**
     * Switches to a different audio rendition.
     *
     * Passing `null` disables audio playback. If that would leave both media kinds disabled,
     * this call throws.
     */
    fun switchAudioTrack(trackName: String?) {
        check(!closed) { "Player is already closed" }
        val newTrack = resolveAudioTrack(trackName)
        if (newTrack?.name == selectedAudioTrack?.name) {
            return
        }
        check(selectedVideoTrack != null || newTrack != null) {
            "at least one audio or video track is expected"
        }

        val currentTrack = selectedAudioTrack
        selectedAudioTrack = newTrack

        if (!playing) {
            return
        }

        if (currentTrack != null && newTrack != null && audioRenderer != null) {
            switchActiveAudioTrack(newTrack)
            return
        }

        restartPlaybackForSelectionChange()
    }

    /**
     * Pauses playback by stopping all decoders and cancelling ingest coroutines.
     *
     * Unlike [close], the player can be resumed by calling [play] again.
     */
    fun pause() {
        check(!closed) { "Player is already closed" }
        if (!playing) {
            return
        }

        Log.d(TAG, "pause")
        playing = false
        teardownPlayback(resetAccumulator = false)

        if (selectedAudioTrack != null) {
            _events.tryEmit(Event.TrackPaused("audio"))
        }
        if (selectedVideoTrack != null) {
            _events.tryEmit(Event.TrackPaused("video"))
        }
    }

    /**
     * Stops playback and resets all accumulated metrics.
     *
     * Call [play] again to restart from the current selected tracks.
     */
    fun stop() {
        check(!closed) { "Player is already closed" }
        if (!playing && audioRenderer == null && videoRenderer == null) {
            accumulator.reset()
            return
        }

        Log.d(TAG, "stop")
        playing = false
        teardownPlayback(resetAccumulator = true)
    }

    /**
     * Adjusts the target playback latency while the player is running.
     */
    fun updateTargetLatency(ms: Int) {
        check(!closed) { "Player is already closed" }
        targetLatencyMs = ms
        audioRenderer?.updateTargetLatency(ms)
        videoRenderer?.updateTargetBuffering(ms)
    }

    /**
     * Releases the retained broadcast handle and all playback resources.
     *
     * After [close] returns the player cannot be used again.
     */
    override fun close() {
        if (closed) {
            return
        }

        closed = true
        playing = false
        teardownPlayback(resetAccumulator = true)
        scope.cancel()
        broadcastOwner.release()
    }

    private fun startAudio() {
        val audioInfo = selectedAudioTrack ?: run {
            Log.d(TAG, "No audio track selected, skipping audio pipeline")
            return
        }

        Log.d(
            TAG,
            "startAudio: '${audioInfo.name}' ${audioInfo.config.sampleRate}Hz " +
                "${audioInfo.config.channelCount}ch, targetLatency=${targetLatencyMs}ms",
        )

        val renderer = AudioRenderer(
            config = audioInfo.rawConfig,
            targetLatencyMs = targetLatencyMs,
            metrics = accumulator,
        )
        audioRenderer = renderer
        renderer.start()

        val audioFlow = subscribeTrack(
            broadcastOwner.consumer(),
            audioInfo.name,
            audioInfo.rawConfig.container,
            targetLatencyMs.toULong(),
        )

        audioIngestJob = scope.launch {
            var firstFrame = true
            try {
                audioFlow.collect { frame ->
                    renderer.submitFrame(frame.payload, frame.timestampUs.toLong())
                    accumulator.recordAudioBytes(frame.payload.size)

                    if (firstFrame) {
                        firstFrame = false
                        accumulator.markFirstAudioFrame()
                        Log.d(TAG, "First audio frame received")
                        _events.tryEmit(Event.TrackPlaying("audio"))
                    }
                }

                _events.tryEmit(Event.TrackStopped("audio"))
            } catch (e: Exception) {
                Log.e(TAG, "Audio ingest error: $e")
                _events.tryEmit(Event.Error("audio", e.message ?: "Unknown error"))
            }
            checkAllStopped()
        }
    }

    private fun startVideo(surface: Surface) {
        val videoInfo = selectedVideoTrack ?: run {
            Log.d(TAG, "No video track selected, skipping video pipeline")
            return
        }

        Log.d(TAG, "Starting video: '${videoInfo.name}' codec=${videoInfo.config.codec}")

        val track = VideoRendererTrack(videoInfo.rawConfig, targetLatencyMs.toLong() * 1000)
        val renderer = VideoRenderer(
            activeTrack = track,
            outputSurface = surface,
            timebase = audioRenderer?.timebase,
            metrics = accumulator,
            onError = ::handleVideoRendererError,
        )
        videoRenderer = renderer
        renderer.start()

        videoIngestJob = launchVideoIngestJob(videoInfo, track)
    }

    private fun launchVideoIngestJob(videoInfo: VideoTrackInfo, track: VideoRendererTrack): Job {
        Log.d(TAG, "Subscribing to video track '${videoInfo.name}'")
        val videoFlow = subscribeTrack(
            broadcastOwner.consumer(),
            videoInfo.name,
            videoInfo.rawConfig.container,
            targetLatencyMs.toULong(),
        )

        return scope.launch {
            var firstFrame = true
            try {
                Log.d(TAG, "Waiting for video frames")
                videoFlow.collect { frame ->
                    track.insert(frame.payload, frame.timestampUs.toLong(), frame.keyframe)
                    accumulator.recordVideoBytes(frame.payload.size)

                    if (firstFrame) {
                        firstFrame = false
                        accumulator.markFirstVideoFrame()
                        Log.d(TAG, "First video frame received")
                        _events.tryEmit(Event.TrackPlaying("video"))
                    }
                }

                _events.tryEmit(Event.TrackStopped("video"))
            } catch (_: CancellationException) {
                Log.d(TAG, "Video ingest cancelled")
            } catch (e: Exception) {
                Log.e(TAG, "Video ingest error: $e")
                _events.tryEmit(Event.Error("video", e.message ?: "Unknown error"))
            }
            checkAllStopped()
        }
    }

    private fun switchActiveVideoTrack(videoInfo: VideoTrackInfo, renderer: VideoRenderer) {
        Log.d(TAG, "Switching video track to '${videoInfo.name}' codec=${videoInfo.config.codec}")

        val newTrack = VideoRendererTrack(videoInfo.rawConfig, targetLatencyMs.toLong() * 1000)
        val oldJob = videoIngestJob
        // TODO: If the pending track never activates, this old job lives until a broader
        // playback teardown cancels it.
        renderer.setPendingTrack(newTrack) {
            oldJob?.cancel()
        }

        videoIngestJob = launchVideoIngestJob(videoInfo, newTrack)
    }

    private fun switchActiveAudioTrack(audioInfo: AudioTrackInfo) {
        Log.d(TAG, "Switching audio track to '${audioInfo.name}' codec=${audioInfo.config.codec}")

        audioIngestJob?.cancel()
        audioRenderer?.stop()
        audioRenderer = null
        startAudio()
    }

    private fun restartPlaybackForSelectionChange() {
        Log.d(TAG, "Restarting playback for selection change")
        teardownPlayback(resetAccumulator = false)
        if (playing) {
            startAudio()
            surface?.let { startVideo(it) }
        }
    }

    private fun swapVideoSurface(surface: Surface) {
        val renderer = videoRenderer ?: return

        try {
            renderer.setSurface(surface)
            Log.d(TAG, "Updated video output surface")
        } catch (t: Throwable) {
            Log.w(TAG, "Surface swap failed, restarting video renderer", t)
            restartVideoForSurfaceChange(surface)
        }
    }

    private fun restartVideoForSurfaceChange(surface: Surface) {
        stopVideo()
        if (playing && selectedVideoTrack != null) {
            startVideo(surface)
        }
    }

    private fun handleVideoRendererError(error: Throwable) {
        Log.e(TAG, "Video renderer error", error)
        stopVideo()
        _events.tryEmit(Event.Error("video", error.message ?: "Unknown error"))
        checkAllStopped()
    }

    private fun stopVideo() {
        videoIngestJob?.cancel()
        videoIngestJob = null
        videoRenderer?.stop()
        videoRenderer = null
    }

    private fun teardownPlayback(resetAccumulator: Boolean) {
        audioIngestJob?.cancel()
        audioIngestJob = null
        videoIngestJob?.cancel()
        videoIngestJob = null
        audioRenderer?.stop()
        audioRenderer = null
        videoRenderer?.stop()
        videoRenderer = null
        if (resetAccumulator) {
            accumulator.reset()
        }
    }

    private fun checkAllStopped() {
        val audioDone = audioIngestJob?.isActive != true
        val videoDone = videoIngestJob?.isActive != true
        if (audioDone && videoDone) {
            _events.tryEmit(Event.AllTracksStopped)
        }
    }

    private fun resolveVideoTrack(trackName: String?): VideoTrackInfo? {
        if (trackName == null) {
            return null
        }
        return catalog.videoTracks.firstOrNull { it.name == trackName }
            ?: throw IllegalArgumentException(
                "Unknown video track '$trackName' for catalog ${catalog.path}",
            )
    }

    private fun resolveAudioTrack(trackName: String?): AudioTrackInfo? {
        if (trackName == null) {
            return null
        }
        return catalog.audioTracks.firstOrNull { it.name == trackName }
            ?: throw IllegalArgumentException(
                "Unknown audio track '$trackName' for catalog ${catalog.path}",
            )
    }
}
