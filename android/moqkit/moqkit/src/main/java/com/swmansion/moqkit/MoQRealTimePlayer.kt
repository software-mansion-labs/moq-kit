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
 * Uses MediaCodec (async) for decoding, AudioTrack (MODE_STREAM) for audio output,
 * and Surface-configured MediaCodec for video output — bypassing ExoPlayer for lower latency.
 */
class MoQRealTimePlayer(
    private val tracks: List<MoQTrackInfo>,
    private val targetLatencyMs: Int = 100,
    parentScope: CoroutineScope,
) {
    sealed class Event {
        data class TrackPlaying(val kind: String) : Event()
        data class TrackStopped(val kind: String) : Event()
        data class Error(val kind: String, val message: String) : Event()
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
        return accumulator.snapshot(audioLatencyMs = audioLatency, videoLatencyMs = videoLatency)
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
                            renderer.flush()
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

    fun pause() {
        stop()
    }

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

    fun updateTargetLatency(ms: Int) {
        audioRenderer?.updateTargetLatency(ms)
        videoRenderer?.updateTargetBuffering(ms)
    }
}
