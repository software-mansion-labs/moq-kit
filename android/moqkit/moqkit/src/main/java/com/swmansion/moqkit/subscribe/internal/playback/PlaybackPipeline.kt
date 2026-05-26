package com.swmansion.moqkit.subscribe.internal.playback

import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.subscribe.AudioTrackInfo
import com.swmansion.moqkit.subscribe.BroadcastOwner
import com.swmansion.moqkit.subscribe.Catalog
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import com.swmansion.moqkit.subscribe.internal.subscribeTrack
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import java.time.Duration

private const val TAG = "PlaybackPipeline"
private const val PTS_CORRECTION_THRESHOLD_US = 2_000_000L

internal enum class PlaybackPipelineSwitchOutcome {
    HANDLED,
    RESTART_REQUIRED,
}

/**
 * Owns Android playback execution for the selected media tracks.
 *
 * One pipeline instance covers all selected-track combinations:
 * - audio + video: audio playback drives the shared clock
 * - audio only: audio playback drives the shared clock
 * - video only: the video renderer drives a wall-clock-backed timeline
 */
internal class PlaybackPipeline(
    private val catalog: Catalog,
    private val broadcastOwner: BroadcastOwner,
    videoTrack: VideoTrackInfo?,
    audioTrack: AudioTrackInfo?,
    targetBuffering: Duration,
    initialVolume: Float,
    initialSurface: Surface?,
    private val scope: CoroutineScope,
    private val statsTracker: PlaybackStatsTracker,
) {
    private val timestampAligner = MediaTimestampAligner()
    private val frameObserver = CompositeMediaFrameObserver(listOf(statsTracker, timestampAligner))
    private val clock: MediaClock = if (audioTrack != null) AudioDrivenClock() else VideoDrivenClock()
    private val stateLock = Any()

    private var selectedVideoTrack: VideoTrackInfo? = videoTrack
    private var selectedAudioTrack: AudioTrackInfo? = audioTrack
    private var targetBuffering = targetBuffering
    private var storedAudioVolume = initialVolume.coerceIn(0f, 1f)
    private var surface: Surface? = initialSurface
    private var videoEpoch: Long = if (videoTrack != null) 1L else 0L
    private var audioEpoch: Long = if (audioTrack != null) 1L else 0L

    private var audioRenderer: AudioRenderer? = null
    private var videoRenderer: VideoRenderer? = null
    private var audioIngestJob: Job? = null
    private var videoIngestJob: Job? = null
    private var coordinatorJob: Job? = null
    private var pendingVideoCleanup: TrackIngestHandle? = null

    val currentTimeUs: Long
        get() = clock.currentTimeUs

    init {
        require(videoTrack != null || audioTrack != null) {
            "at least one audio or video track is expected"
        }

        startAudio()
        initialSurface?.let { startVideo(it) }
        restartCoordinator()
    }

    fun snapshotStats(): PlaybackStats {
        val hasAudio = audioRenderer != null
        val hasVideo = videoRenderer != null
        val currentTimeUs = clock.currentTimeUs
        val audioLiveTime = if (hasAudio) timestampAligner.audioLiveEdge.estimatedLivePTS() else null
        val videoLiveTime = if (hasVideo) videoLiveTimeForStats(hasAudio) else null

        return statsTracker.snapshot(
            audioLatency = playbackLatency(audioLiveTime, currentTimeUs),
            videoLatency = playbackLatency(videoLiveTime, currentTimeUs),
            audioRingBuffer = audioRenderer?.bufferFill,
            videoJitterBuffer = videoRenderer?.bufferFill,
            videoDecodeStatsEnabled = hasVideo,
        )
    }

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
                if (selectedVideoTrack != null) {
                    startVideo(surface)
                    restartCoordinator()
                }
            }

            previousSurface !== surface -> swapVideoSurface(surface)
        }
    }

    fun updateTargetLatency(latency: Duration) {
        targetBuffering = latency
        audioRenderer?.updateTargetLatency(latency)
        videoRenderer?.updateTargetBuffering(latency)
    }

    fun setVolume(volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)
        storedAudioVolume = clamped
        audioRenderer?.setVolume(clamped)
    }

    fun switchVideo(track: VideoTrackInfo): PlaybackPipelineSwitchOutcome {
        val renderer = videoRenderer ?: return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        if (renderer.hasPendingTrack) return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED

        Log.d(TAG, "Switching video track to '${track.name}' codec=${track.config.codec}")

        val nextEpoch = videoEpoch + 1L
        statsTracker.emitSubscribeStart(MediaFrameKind.VIDEO, track.name, nextEpoch)
        val newTrack = VideoRendererTrack(
            trackName = track.name,
            trackEpoch = nextEpoch,
            config = track.rawConfig,
            targetBuffering = targetBuffering,
        )
        val oldHandle = TrackIngestHandle(videoIngestJob)
        synchronized(stateLock) {
            pendingVideoCleanup?.close()
            pendingVideoCleanup = oldHandle
        }

        renderer.setPendingTrack(newTrack) {
            oldHandle.close()
            synchronized(stateLock) {
                if (pendingVideoCleanup === oldHandle) {
                    pendingVideoCleanup = null
                }
            }
            statsTracker.emitTrackSwitch(MediaFrameKind.VIDEO, track.name, nextEpoch)
        }

        selectedVideoTrack = track
        videoEpoch = nextEpoch
        videoIngestJob = launchVideoIngestJob(track, newTrack, nextEpoch)
        restartCoordinator()
        return PlaybackPipelineSwitchOutcome.HANDLED
    }

    fun switchAudio(track: AudioTrackInfo): PlaybackPipelineSwitchOutcome {
        val renderer = audioRenderer ?: return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        if (!renderer.canAcceptConfig(track.rawConfig)) {
            return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        }

        Log.d(TAG, "Switching audio track to '${track.name}' codec=${track.config.codec}")

        val nextEpoch = audioEpoch + 1L
        statsTracker.emitSubscribeStart(MediaFrameKind.AUDIO, track.name, nextEpoch)
        val oldJob = audioIngestJob
        selectedAudioTrack = track
        audioEpoch = nextEpoch
        audioIngestJob = launchAudioIngestJob(track, renderer, nextEpoch)
        oldJob?.cancel()
        restartCoordinator()
        return PlaybackPipelineSwitchOutcome.HANDLED
    }

    fun stop() {
        coordinatorJob?.cancel()
        coordinatorJob = null

        audioIngestJob?.cancel()
        videoIngestJob?.cancel()
        audioIngestJob = null
        videoIngestJob = null

        synchronized(stateLock) {
            pendingVideoCleanup?.close()
            pendingVideoCleanup = null
        }

        audioRenderer?.stop()
        videoRenderer?.stop()
        audioRenderer = null
        videoRenderer = null
    }

    private fun startAudio() {
        val audioInfo = selectedAudioTrack ?: run {
            Log.d(TAG, "No audio track selected, skipping audio pipeline")
            return
        }
        val audioClock = clock as? AudioDrivenClock
            ?: error("AudioRenderer requires an AudioDrivenClock")

        Log.d(
            TAG,
            "Starting audio: '${audioInfo.name}' ${audioInfo.config.sampleRate}Hz " +
                "${audioInfo.config.channelCount}ch, targetBuffering=${targetBuffering.toMillisecondsLongClamped()}ms",
        )

        val renderer = AudioRenderer(
            config = audioInfo.rawConfig,
            targetBuffering = targetBuffering,
            metrics = statsTracker,
            initialVolume = storedAudioVolume,
            clock = audioClock,
        )
        audioRenderer = renderer
        renderer.start()
        statsTracker.emitSubscribeStart(MediaFrameKind.AUDIO, audioInfo.name, audioEpoch)
        audioIngestJob = launchAudioIngestJob(audioInfo, renderer, audioEpoch)
    }

    private fun startVideo(surface: Surface) {
        val videoInfo = selectedVideoTrack ?: run {
            Log.d(TAG, "No video track selected, skipping video pipeline")
            return
        }

        Log.d(TAG, "Starting video: '${videoInfo.name}' codec=${videoInfo.config.codec}")

        statsTracker.resetVideoDecodeStats(videoInfo.name)
        val track = VideoRendererTrack(
            trackName = videoInfo.name,
            trackEpoch = videoEpoch,
            config = videoInfo.rawConfig,
            targetBuffering = targetBuffering,
        )
        val renderer = VideoRenderer(
            activeTrack = track,
            outputSurface = surface,
            clock = clock,
            timestampAligner = timestampAligner,
            metrics = statsTracker,
            onError = ::handleVideoRendererError,
        )
        videoRenderer = renderer
        renderer.start()
        statsTracker.emitSubscribeStart(MediaFrameKind.VIDEO, videoInfo.name, videoEpoch)
        videoIngestJob = launchVideoIngestJob(videoInfo, track, videoEpoch)
    }

    private fun launchAudioIngestJob(
        audioInfo: AudioTrackInfo,
        renderer: AudioRenderer,
        trackEpoch: Long,
    ): Job {
        val audioFlow = subscribeTrack(
            broadcastOwner.consumer(),
            audioInfo.name,
            audioInfo.rawConfig.container,
            targetBuffering.toMillisecondsLongClamped().toULong(),
        )

        return scope.launch {
            var firstFrame = true
            var lastPtsUs: Long? = null
            try {
                frameObserver.onMediaTrackStarted(MediaFrameKind.AUDIO)
                audioFlow.collect { frame ->
                    val timestampUs = frame.timestampUs.toLong()
                    val previousPtsUs = lastPtsUs
                    if (isDiscontinuity(timestampUs, previousPtsUs, keyframe = true)) {
                        val gapUs = timestampGapUs(timestampUs, requireNotNull(previousPtsUs))
                        Log.d(TAG, "Audio discontinuity detected (gap=${gapUs}us)")
                        renderer.flush()
                        frameObserver.onFrameDiscontinuity(MediaFrameKind.AUDIO, gapUs)
                    }
                    lastPtsUs = timestampUs

                    frameObserver.onMediaFrame(frame, MediaFrameKind.AUDIO)
                    if (firstFrame) {
                        firstFrame = false
                        Log.d(TAG, "First audio frame received track='${audioInfo.name}' epoch=$trackEpoch")
                        renderer.expectPlaybackStart(
                            TrackReadyContext(
                                kind = MediaFrameKind.AUDIO,
                                trackName = audioInfo.name,
                                sourceTimestampUs = timestampUs,
                                targetBuffering = targetBuffering,
                                trackEpoch = trackEpoch,
                                keyframe = frame.keyframe,
                                payloadBytes = frame.payload.size,
                            ),
                        )
                    }
                    renderer.submitFrame(frame.payload, timestampUs)
                }

                statsTracker.emitSubscribeEnd(MediaFrameKind.AUDIO, audioInfo.name, trackEpoch)
            } catch (_: CancellationException) {
                Log.d(TAG, "Audio ingest cancelled")
            } catch (e: Exception) {
                Log.e(TAG, "Audio ingest error", e)
                statsTracker.emitSubscribeError(
                    MediaFrameKind.AUDIO,
                    audioInfo.name,
                    e.message ?: "Unknown error",
                    trackEpoch,
                )
            }
        }
    }

    private fun launchVideoIngestJob(
        videoInfo: VideoTrackInfo,
        track: VideoRendererTrack,
        trackEpoch: Long,
    ): Job {
        Log.d(TAG, "Subscribing to video track '${videoInfo.name}'")
        val videoFlow = subscribeTrack(
            broadcastOwner.consumer(),
            videoInfo.name,
            videoInfo.rawConfig.container,
            targetBuffering.toMillisecondsLongClamped().toULong(),
        )

        return scope.launch {
            var firstFrame = true
            var lastPtsUs: Long? = null
            try {
                frameObserver.onMediaTrackStarted(MediaFrameKind.VIDEO)
                videoFlow.collect { frame ->
                    val timestampUs = frame.timestampUs.toLong()
                    val previousPtsUs = lastPtsUs
                    if (isDiscontinuity(timestampUs, previousPtsUs, frame.keyframe)) {
                        val gapUs = timestampGapUs(timestampUs, requireNotNull(previousPtsUs))
                        Log.d(TAG, "Video discontinuity detected (gap=${gapUs}us)")
                        frameObserver.onFrameDiscontinuity(MediaFrameKind.VIDEO, gapUs)
                    }
                    lastPtsUs = timestampUs

                    frameObserver.onMediaFrame(frame, MediaFrameKind.VIDEO)
                    val accepted = track.insert(frame.payload, timestampUs, frame.keyframe)

                    if (accepted && firstFrame) {
                        firstFrame = false
                        Log.d(TAG, "First video frame accepted track='${videoInfo.name}' epoch=$trackEpoch")
                        statsTracker.emitTrackReady(
                            TrackReadyContext(
                                kind = MediaFrameKind.VIDEO,
                                trackName = videoInfo.name,
                                sourceTimestampUs = timestampUs,
                                targetBuffering = targetBuffering,
                                trackEpoch = trackEpoch,
                                keyframe = frame.keyframe,
                                payloadBytes = frame.payload.size,
                            ),
                        )
                    }
                }

                statsTracker.emitSubscribeEnd(MediaFrameKind.VIDEO, videoInfo.name, trackEpoch)
            } catch (_: CancellationException) {
                Log.d(TAG, "Video ingest cancelled")
            } catch (e: Exception) {
                Log.e(TAG, "Video ingest error", e)
                statsTracker.emitSubscribeError(
                    MediaFrameKind.VIDEO,
                    videoInfo.name,
                    e.message ?: "Unknown error",
                    trackEpoch,
                )
            }
        }
    }

    private fun restartCoordinator() {
        coordinatorJob?.cancel()
        val jobs = listOfNotNull(audioIngestJob, videoIngestJob)
        if (jobs.isEmpty()) {
            coordinatorJob = null
            return
        }

        val videoTrackName = selectedVideoTrack?.name
        val audioTrackName = selectedAudioTrack?.name
        coordinatorJob = scope.launch {
            try {
                jobs.joinAll()
            } catch (_: CancellationException) {
                return@launch
            }
            Log.d(
                TAG,
                "Playback coordinator observed all tracks stopped; " +
                    "video=${videoTrackName ?: "none"}, audio=${audioTrackName ?: "none"}",
            )
            statsTracker.emitPlaybackEnd(null)
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
        if (selectedVideoTrack != null) {
            startVideo(surface)
            restartCoordinator()
        }
    }

    private fun handleVideoRendererError(error: Throwable) {
        Log.e(TAG, "Video renderer error", error)
        val hadAudio = audioIngestJob?.isActive == true
        stopVideo()
        val trackName = selectedVideoTrack?.name ?: "video"
        statsTracker.emitDecodeError(MediaFrameKind.VIDEO, trackName, error.message ?: "Unknown error")
        if (!hadAudio) {
            statsTracker.emitPlaybackEnd(error.message)
        }
    }

    private fun stopVideo() {
        coordinatorJob?.cancel()
        coordinatorJob = null

        videoIngestJob?.cancel()
        videoIngestJob = null

        synchronized(stateLock) {
            pendingVideoCleanup?.close()
            pendingVideoCleanup = null
        }

        videoRenderer?.stop()
        videoRenderer = null
        restartCoordinator()
    }

    private fun videoLiveTimeForStats(hasAudio: Boolean): Long? {
        val videoTime = timestampAligner.videoLiveEdge.estimatedLivePTS()
            ?.takeIf { it >= 0L }
            ?: return null
        if (!hasAudio) return videoTime
        return timestampAligner.audioTime(
            videoTime = videoTime,
            threshold = PTS_CORRECTION_THRESHOLD_US,
        )
    }

    private fun playbackLatency(liveTime: Long?, currentTimeUs: Long): Duration? {
        val live = liveTime ?: return null
        val latencyUs = try {
            Math.subtractExact(live, currentTimeUs)
        } catch (_: ArithmeticException) {
            return null
        }
        return durationFromMicroseconds(maxOf(0L, latencyUs))
    }

    private fun isDiscontinuity(currentUs: Long, lastUs: Long?, keyframe: Boolean): Boolean {
        val previous = lastUs ?: return false
        if (!keyframe) return false
        return timestampGapUs(currentUs, previous) > 500_000L
    }

    private fun timestampGapUs(currentUs: Long, lastUs: Long): Long =
        if (currentUs >= lastUs) currentUs - lastUs else lastUs - currentUs
}

private class TrackIngestHandle(
    private var job: Job?,
) {
    private val lock = Any()

    fun close() {
        val jobToCancel = synchronized(lock) {
            val value = job
            job = null
            value
        }
        jobToCancel?.cancel()
    }
}
