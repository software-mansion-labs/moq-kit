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
 * @param tracks List of tracks to play. Must contain at least one [MoQAudioTrackInfo];
 *   a [MoQVideoTrackInfo] is optional.
 * @param targetLatencyMs Target end-to-end playback latency in milliseconds. Lower values
 *   reduce delay at the cost of increased risk of stalls. Defaults to 100 ms.
 * @param parentScope Coroutine scope whose lifetime bounds the player's internal coroutines.
 */
class MoQPlayer(
    private val tracks: List<MoQTrackInfo>,
    private val targetLatencyMs: Int = 100,
    parentScope: CoroutineScope,
) {
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
     * once [setSurface] is called.
     */
    fun play() {
        playing = true
        accumulator.markPlayStart()

        val audioInfo = tracks.filterIsInstance<MoQAudioTrackInfo>().firstOrNull()
        if (audioInfo == null) {
            Log.w(TAG, "No audio track found")
            _events.tryEmit(Event.Error("audio", "No audio track"))
            return
        }

        Log.d(TAG, "play: audio='${audioInfo.name}' ${audioInfo.config.sampleRate}Hz " +
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
            var lastPtsUs = 0L
            var firstFrame = true
            try {
                audioFlow.collect { frame ->
                    val tsUs = frame.timestampUs.toLong()

                    // Discontinuity detection: keyframe with >500ms PTS jump
                    if (frame.keyframe && lastPtsUs > 0) {
                        val diff = if (tsUs > lastPtsUs) tsUs - lastPtsUs else lastPtsUs - tsUs
                        if (diff > 500_000) {
                            Log.d(TAG, "Audio discontinuity detected, flushing")
                            renderer.flush()
                        }
                    }
                    lastPtsUs = tsUs

                    renderer.submitFrame(frame.payload, tsUs)
                    accumulator.recordAudioBytes(frame.payload.size)

                    if (firstFrame) {
                        firstFrame = false
                        accumulator.markFirstAudioFrame()
                        Log.d(TAG, "First audio frame received")
                        _events.tryEmit(Event.TrackPlaying("audio"))
                    }
                }
                Log.d(TAG, "Audio flow ended")
                _events.tryEmit(Event.TrackStopped("audio"))
            } catch (e: Exception) {
                Log.e(TAG, "Audio ingest error: $e")
                _events.tryEmit(Event.Error("audio", e.message ?: "Unknown error"))
            }
            checkAllStopped()
        }

        // Start video if surface is available
        val s = surface
        if (s != null) {
            startVideo(s)
        }
    }

    private fun startVideo(surface: Surface) {
        val videoInfo = tracks.filterIsInstance<MoQVideoTrackInfo>().firstOrNull() ?: return

        Log.d(TAG, "Starting video: '${videoInfo.name}' codec=${videoInfo.config.codec}")

        val renderer = VideoRenderer(
            config = videoInfo.config,
            surface = surface,
            targetBufferingUs = targetLatencyMs.toLong() * 1000,
            timebase = audioRenderer?.timebase,
            metrics = accumulator,
        )
        videoRenderer = renderer
        renderer.start()

        val videoFlow = subscribeTrack(
            videoInfo.broadcast,
            videoInfo.name,
            videoInfo.config.container,
            targetLatencyMs.toULong(),
        )

        videoIngestJob = scope.launch {
            var lastPtsUs = 0L
            var firstFrame = true
            try {
                videoFlow.collect { frame ->
                    val tsUs = frame.timestampUs.toLong()

                    // Discontinuity detection: keyframe with >500ms PTS jump
                    if (frame.keyframe && lastPtsUs > 0) {
                        val diff = if (tsUs > lastPtsUs) tsUs - lastPtsUs else lastPtsUs - tsUs
                        if (diff > 500_000) {
                            Log.d(TAG, "Video discontinuity detected, flushing")
                            // renderer.flush()
                        }
                    }
                    lastPtsUs = tsUs

                    renderer.submitFrame(frame.payload, tsUs, frame.keyframe)
                    accumulator.recordVideoBytes(frame.payload.size)

                    if (firstFrame) {
                        firstFrame = false
                        accumulator.markFirstVideoFrame()
                        Log.d(TAG, "First video frame received")
                        _events.tryEmit(Event.TrackPlaying("video"))
                    }
                }
                Log.d(TAG, "Video flow ended")
                _events.tryEmit(Event.TrackStopped("video"))
            } catch (e: Exception) {
                Log.e(TAG, "Video ingest error: $e")
                _events.tryEmit(Event.Error("video", e.message ?: "Unknown error"))
            }
            checkAllStopped()
        }
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
