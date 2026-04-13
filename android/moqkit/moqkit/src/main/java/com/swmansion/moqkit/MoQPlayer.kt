package com.swmansion.moqkit

import android.util.Log
import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch

private const val TAG = "MoQRealTimePlayer"

/**
 * Real-time audio+video player with fine-grained latency control.
 *
 * Uses MediaCodec (async) for decoding, AudioTrack (MODE_STREAM) for audio output,
 * and a Surface-configured MediaCodec for video output — bypassing ExoPlayer for lower latency.
 *
 * ### Typical usage
 * ```kotlin
 * val player = MoQPlayer(broadcastInfo.videoTracks + broadcastInfo.audioTracks,
 *                        targetLatencyMs = 150, parentScope = lifecycleScope)
 * player.setSurface(surfaceView.holder.surface)
 * player.play()
 * // … later …
 * player.stop()
 * ```
 *
 * @param tracks List of tracks to play. Both [MoQAudioTrackInfo] and [MoQVideoTrackInfo] are
 *   optional — any combination works, including video-only or audio-only.
 * @param targetLatencyMs Target end-to-end playback latency in milliseconds. Lower values
 *   reduce delay at the cost of increased risk of stalls. Defaults to 100 ms.
 * @param parentScope Coroutine scope whose lifetime bounds the player's internal coroutines.
 */
class MoQPlayer(
    private val tracks: List<MoQTrackInfo>,
    private val targetLatencyMs: Int = 100,
    parentScope: CoroutineScope,
) {
    init {
        val audioTracksCount = tracks.count { track ->  track is MoQAudioTrackInfo }
        if (audioTracksCount > 1) {
            throw IllegalArgumentException("at most one audio track is allowed")
        }
        val videoTracksCount = tracks.count { track -> track is MoQVideoTrackInfo }
        if (videoTracksCount > 1) {
            throw IllegalArgumentException("at most one video track is allowed")
        }
        if (audioTracksCount + videoTracksCount == 0) {
            throw IllegalArgumentException("at least one audio or video track is expected")
        }
    }

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

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 8)
    val events: SharedFlow<Event> = _events

    private var audioRenderer: AudioRenderer? = null
    private var videoRenderer: VideoRenderer? = null
    private var audioIngestJob: Job? = null
    private var videoIngestJob: Job? = null
    private var surface: Surface? = null
    private var playing = false
    private val accumulator = PlaybackMetricsAccumulator()

    /** Current playback time in microseconds. */
    val currentTimeUs: Long get() = audioRenderer?.currentTimeUs ?: 0L

    /** Snapshot of current playback metrics. */
    val stats: PlaybackStats get() {
        val timeUs = audioRenderer?.currentTimeUs ?: 0L
        val audioLatency = audioRenderer?.let {
            if (it.lastIngestPtsUs > 0 && timeUs > 0) (it.lastIngestPtsUs - timeUs).toDouble() / 1000.0 else null
        }
        val videoLatency = videoRenderer?.let {
            if (it.lastIngestPtsUs > 0 && timeUs > 0) (it.lastIngestPtsUs - timeUs).toDouble() / 1000.0 else null
        }
        return accumulator.snapshot(
            audioLatencyMs = audioLatency,
            videoLatencyMs = videoLatency,
            audioRingBufferMs = audioRenderer?.bufferFillMs,
            videoJitterBufferMs = videoRenderer?.bufferFillMs,
        )
    }

    /**
     * Set or clear the video output surface.
     * If play() was already called and a surface becomes available, starts the video pipeline.
     * If surface becomes null, stops the video renderer.
     */
    fun setSurface(surface: Surface?) {
        this.surface = surface
        if (surface != null && playing && videoRenderer == null) {
            startVideo(surface)
        } else if (surface == null && videoRenderer != null) {
            stopVideo()
        }
    }

    /**
     * Starts audio (and video, if a surface is set) playback.
     *
     * Opens subscriptions for all tracks in the list provided at construction time and begins
     * decoding. The first decoded audio frame triggers an [Event.TrackPlaying] event.
     * Safe to call if a surface has not yet been provided — video will start automatically
     * once [setSurface] is called. Audio is optional — if no audio track is present only
     * video is played.
     */
    fun play() {
        playing = true
        accumulator.markPlayStart()

        startAudio()

        surface?.let {
            startVideo(it)
        }
    }

    private fun startAudio() {
        val audioInfo = tracks.filterIsInstance<MoQAudioTrackInfo>().firstOrNull() ?: run {
            Log.d(TAG, "No audio track, skipping audio pipeline")
            return
        }

        Log.d(TAG, "startAudio: '${audioInfo.name}' ${audioInfo.config.sampleRate}Hz " +
            "${audioInfo.config.channelCount}ch, targetLatency=${targetLatencyMs}ms")

        val renderer = AudioRenderer(
            config = audioInfo.config,
            targetLatencyMs = targetLatencyMs,
            metrics = accumulator,
        )
        audioRenderer = renderer
        renderer.start()

        val audioFlow = subscribeTrack(
            audioInfo.broadcast,
            audioInfo.name,
            audioInfo.config.container,
            targetLatencyMs.toULong(),
        )

        audioIngestJob = scope.launch {
            var firstFrame = true
            try {
                audioFlow.collect { frame ->
                    // TODO: add discontinuation detection
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
        val videoInfo = tracks.filterIsInstance<MoQVideoTrackInfo>().firstOrNull() ?: return

        Log.d(TAG, "Starting video: '${videoInfo.name}' codec=${videoInfo.config.codec}")

        val track = VideoRendererTrack(videoInfo.config, targetLatencyMs.toLong() * 1000)

        val renderer = VideoRenderer(
            activeTrack = track,
            surface = surface,
            timebase = audioRenderer?.timebase,
            metrics = accumulator,
        )
        videoRenderer = renderer
        renderer.start()

        videoIngestJob = launchVideoIngestJob(videoInfo, track)
    }

    private fun launchVideoIngestJob(videoInfo: MoQVideoTrackInfo, track: VideoRendererTrack): Job {
        Log.d(TAG, "Subscribing to video track")
        val videoFlow = subscribeTrack(
            videoInfo.broadcast,
            videoInfo.name,
            videoInfo.config.container,
            targetLatencyMs.toULong(),
        )

        return scope.launch {
            var firstFrame = true
            try {
                Log.d(TAG, "Waiting for video frames")
                videoFlow.collect { frame ->
                    // TODO: add discontinuation detection

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
            } catch (e: Exception) {
                Log.e(TAG, "Video ingest error: $e")
                _events.tryEmit(Event.Error("video", e.message ?: "Unknown error"))
            }
            checkAllStopped()
        }
    }

    /**
     * Switches to a different video rendition seamlessly.
     *
     * Creates a pending track that accumulates frames in the background. The swap state
     * machine in [VideoRenderer] decides between a seamless cut-in and a flush-and-swap,
     * then calls [onActivated] on the renderer's HandlerThread.
     *
     * No-ops if a switch is already in progress.
     *
     * @param videoInfo The new video rendition to switch to.
     * @param onActivated Called on the renderer's HandlerThread when the swap completes.
     */
    fun switchVideoTrack(videoInfo: MoQVideoTrackInfo, onActivated: (() -> Unit)? = null) {
        val renderer = videoRenderer ?: return
        if (renderer.hasPendingTrack) return

        Log.d(TAG, "Switching video track to '${videoInfo.name}' codec=${videoInfo.config.codec}")

        val newTrack = VideoRendererTrack(videoInfo.config, targetLatencyMs.toLong() * 1000)
        val oldJob = videoIngestJob

        renderer.setPendingTrack(newTrack) {
            // TODO: we may encounter situation where the track will never be switched so we will leak the job
            oldJob?.cancel()
            onActivated?.invoke()
        }

        videoIngestJob = launchVideoIngestJob(videoInfo, newTrack)
    }

    private fun stopVideo() {
        videoIngestJob?.cancel()
        videoIngestJob = null
        videoRenderer?.stop()
        videoRenderer = null
    }

    private fun checkAllStopped() {
        val audioDone = audioIngestJob?.isActive != true
        val videoDone = videoIngestJob?.isActive != true
        if (audioDone && videoDone) {
            _events.tryEmit(Event.AllTracksStopped)
        }
    }

    /**
     * Pauses playback by stopping all decoders and cancelling ingest coroutines.
     *
     * Unlike [stop], the player can be resumed by calling [play] again. Emits
     * [Event.TrackPaused] for each active track.
     */
    fun pause() {
        Log.d(TAG, "pause")
        playing = false
        audioIngestJob?.cancel()
        audioIngestJob = null
        videoIngestJob?.cancel()
        videoIngestJob = null
        audioRenderer?.stop()
        audioRenderer = null
        videoRenderer?.stop()
        videoRenderer = null

        val hasAudio = tracks.any { it is MoQAudioTrackInfo }
        val hasVideo = tracks.any { it is MoQVideoTrackInfo }
        if (hasAudio) _events.tryEmit(Event.TrackPaused("audio"))
        if (hasVideo) _events.tryEmit(Event.TrackPaused("video"))
    }

    /**
     * Stops playback and resets all accumulated metrics.
     *
     * Releases decoders and cancels ingest coroutines. Call [play] to start again from scratch.
     */
    fun stop() {
        Log.d(TAG, "stop")
        playing = false
        audioIngestJob?.cancel()
        audioIngestJob = null
        videoIngestJob?.cancel()
        videoIngestJob = null
        audioRenderer?.stop()
        audioRenderer = null
        videoRenderer?.stop()
        videoRenderer = null
        accumulator.reset()
    }

    /**
     * Adjusts the target playback latency while the player is running.
     *
     * Propagates the new value to the audio ring buffer and video jitter buffer immediately.
     * Lower values cause more aggressive frame dropping to catch up to live; higher values
     * trade latency for smoother playback.
     *
     * @param ms New target latency in milliseconds.
     */
    fun updateTargetLatency(ms: Int) {
        audioRenderer?.updateTargetLatency(ms)
        videoRenderer?.updateTargetBuffering(ms)
    }
}
