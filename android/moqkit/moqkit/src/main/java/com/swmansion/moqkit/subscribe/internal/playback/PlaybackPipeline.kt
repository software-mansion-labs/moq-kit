package com.swmansion.moqkit.subscribe.internal.playback

import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.subscribe.AudioTrackInfo
import com.swmansion.moqkit.subscribe.DiscontinuityReason
import com.swmansion.moqkit.subscribe.DropReason
import com.swmansion.moqkit.subscribe.DropStage
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineError
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.BroadcastOwner
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.MediaTrackRequest
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionEffect
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionRejectReason
import com.swmansion.moqkit.subscribe.internal.pipeline.DriverKind
import com.swmansion.moqkit.subscribe.internal.pipeline.IngestEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.MonotonicTimeSource
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelinePolicies
import com.swmansion.moqkit.subscribe.internal.pipeline.PlaybackClock
import com.swmansion.moqkit.subscribe.internal.pipeline.RenditionSwitchResources
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineDecision
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineDropReason
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineResetReason
import com.swmansion.moqkit.subscribe.internal.pipeline.TimestampDomainMapper
import com.swmansion.moqkit.subscribe.internal.pipeline.TrackTimeline
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import uniffi.moq.MoqFrame
import java.time.Duration

private const val TAG = "PlaybackPipeline"
private const val TIMELINE_DOMAIN_TOLERANCE_US = 0L

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
    private val broadcastOwner: BroadcastOwner,
    videoTrack: VideoTrackInfo?,
    audioTrack: AudioTrackInfo?,
    targetBuffering: Duration,
    initialVolume: Float,
    initialSurface: Surface?,
    private val scope: CoroutineScope,
    private val statsTracker: PlaybackStatsTracker,
    private val pipelineBus: PipelineBus,
    private val onFatalError: (Throwable) -> Unit,
) {
    private val clock = PlaybackClock(
        PipelinePolicies.clock,
        MonotonicTimeSource,
        masterDriverKind = if (audioTrack != null) DriverKind.AUDIO else DriverKind.VIDEO,
    )
    @Volatile
    private var audioTimeline: TrackTimeline? = null

    private val timestampMapper = TimestampDomainMapper(
        audioTimeline = { audioTimeline },
        videoTimeline = { videoRenderer?.activeTimeline },
    )

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
    private val videoIngestJobs = RenditionSwitchResources<Job>(close = Job::cancel)
    private var coordinatorJob: Job? = null

    val currentTimeUs: Long
        get() = clock.nowMediaUs() ?: 0L

    init {
        require(videoTrack != null || audioTrack != null) {
            "at least one audio or video track is expected"
        }
        Log.i(TAG, "Master clock configured kind=${clock.masterDriverKind}")

        startAudio()
        initialSurface?.let { startVideo(it) }
        restartCoordinator()
    }

    fun snapshotStats(): PlaybackStats {
        val hasAudio = audioRenderer != null
        val hasVideo = videoRenderer != null
        updateTimelinePlaybackPositions(hasAudio)

        return statsTracker.snapshot(
            audioLatency = audioTimeline?.currentLatencyUs()?.let(::durationFromMicroseconds),
            videoLatency = videoRenderer?.activeTimeline?.currentLatencyUs()?.let(::durationFromMicroseconds),
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
        val latencyUs = latency.toMicrosecondsLongClamped()
        audioTimeline?.setTargetLatency(latencyUs)
        audioRenderer?.updateTargetLatency(latency)
        videoRenderer?.updateTargetBuffering(latency)
    }

    fun setVolume(volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)
        storedAudioVolume = clamped
        audioRenderer?.setVolume(clamped)
    }

    @Synchronized
    fun switchVideo(
        track: VideoTrackInfo,
        onAborted: () -> Unit = {},
    ): PlaybackPipelineSwitchOutcome {
        val renderer = videoRenderer ?: return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        if (renderer.hasPendingTrack) return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED

        Log.d(TAG, "Switching video track to '${track.name}' codec=${track.config.codec}")

        val nextEpoch = videoEpoch + 1L
        val timeline = createTimeline()
        statsTracker.emitSubscribeStart(MediaFrameKind.VIDEO, track.name, nextEpoch)
        val newTrack = VideoRendererTrack(
            trackName = track.name,
            trackEpoch = nextEpoch,
            config = track.rawConfig,
            targetBuffering = targetBuffering,
            timeline = timeline,
        )
        val pendingJob = launchVideoIngestJob(track, newTrack, nextEpoch, timeline)
        videoIngestJobs.begin(pendingJob)
        renderer.setPendingTrack(
            track = newTrack,
            onActivated = {
                if (videoIngestJobs.activate(pendingJob)) {
                    selectedVideoTrack = track
                    videoEpoch = nextEpoch
                    statsTracker.emitTrackSwitch(MediaFrameKind.VIDEO, track.name, nextEpoch)
                    restartCoordinator()
                }
            },
            onAborted = {
                if (videoIngestJobs.abort(pendingJob)) onAborted()
            },
        )
        return PlaybackPipelineSwitchOutcome.HANDLED
    }

    fun switchAudio(track: AudioTrackInfo): PlaybackPipelineSwitchOutcome {
        val renderer = audioRenderer ?: return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        if (!renderer.canAcceptConfig(track.rawConfig)) {
            return PlaybackPipelineSwitchOutcome.RESTART_REQUIRED
        }

        Log.d(TAG, "Switching audio track to '${track.name}' codec=${track.config.codec}")

        val nextEpoch = audioEpoch + 1L
        val timeline = createTimeline()
        statsTracker.emitSubscribeStart(MediaFrameKind.AUDIO, track.name, nextEpoch)
        val oldJob = audioIngestJob
        selectedAudioTrack = track
        audioEpoch = nextEpoch
        audioTimeline = timeline
        audioIngestJob = launchAudioIngestJob(track, renderer, nextEpoch, timeline)
        oldJob?.cancel()
        restartCoordinator()
        return PlaybackPipelineSwitchOutcome.HANDLED
    }

    fun stop() {
        coordinatorJob?.cancel()
        coordinatorJob = null

        audioIngestJob?.cancel()
        videoIngestJobs.close()
        audioIngestJob = null

        audioRenderer?.stop()
        videoRenderer?.stop()
        audioRenderer = null
        videoRenderer = null
        audioTimeline = null
    }

    private fun startAudio() {
        val audioInfo = selectedAudioTrack ?: run {
            Log.d(TAG, "No audio track selected, skipping audio pipeline")
            return
        }
        Log.d(
            TAG,
            "Starting audio: '${audioInfo.name}' ${audioInfo.config.sampleRate}Hz " +
                "${audioInfo.config.channelCount}ch, targetBuffering=${targetBuffering.toMillisecondsLongClamped()}ms",
        )

        val timeline = createTimeline()
        val renderer = AudioRenderer(
            trackName = audioInfo.name,
            trackEpoch = audioEpoch,
            config = audioInfo.rawConfig,
            targetBuffering = targetBuffering,
            timeline = timeline,
            metrics = statsTracker,
            pipelineBus = pipelineBus,
            onError = { error -> scope.launch { handleAudioRendererError(error) } },
            initialVolume = storedAudioVolume,
            clock = clock,
        )
        audioRenderer = renderer
        audioTimeline = timeline
        try {
            renderer.start()
            statsTracker.emitSubscribeStart(MediaFrameKind.AUDIO, audioInfo.name, audioEpoch)
            audioIngestJob = launchAudioIngestJob(audioInfo, renderer, audioEpoch, timeline)
        } catch (t: Throwable) {
            renderer.stop()
            audioRenderer = null
            audioTimeline = null
            throw t
        }
    }

    private fun startVideo(surface: Surface) {
        val videoInfo = selectedVideoTrack ?: run {
            Log.d(TAG, "No video track selected, skipping video pipeline")
            return
        }

        Log.d(TAG, "Starting video: '${videoInfo.name}' codec=${videoInfo.config.codec}")

        statsTracker.resetVideoDecodeStats(videoInfo.name)
        val timeline = createTimeline()
        val track = VideoRendererTrack(
            trackName = videoInfo.name,
            trackEpoch = videoEpoch,
            config = videoInfo.rawConfig,
            targetBuffering = targetBuffering,
            timeline = timeline,
        )
        val renderer = VideoRenderer(
            activeTrack = track,
            outputSurface = surface,
            clock = clock,
            timestampMapper = timestampMapper,
            metrics = statsTracker,
            pipelineBus = pipelineBus,
            onError = ::handleVideoRendererError,
        )
        videoRenderer = renderer
        try {
            renderer.start()
            statsTracker.emitSubscribeStart(MediaFrameKind.VIDEO, videoInfo.name, videoEpoch)
            videoIngestJobs.replaceActive(launchVideoIngestJob(videoInfo, track, videoEpoch, timeline))
        } catch (t: Throwable) {
            renderer.stop()
            videoRenderer = null
            throw t
        }
    }

    private fun launchAudioIngestJob(
        audioInfo: AudioTrackInfo,
        renderer: AudioRenderer,
        trackEpoch: Long,
        timeline: TrackTimeline,
    ): Job {
        val audioTrack = broadcastOwner.subscribeMedia(
            MediaTrackRequest(track = audioInfo, targetBuffering = targetBuffering),
        )

        return scope.launch {
            var firstFrame = true
            fun submit(frame: MediaFrame) {
                if (firstFrame) {
                    firstFrame = false
                    Log.d(TAG, "First audio frame received track='${audioInfo.name}' epoch=$trackEpoch")
                    renderer.expectPlaybackStart(
                        TrackReadyContext(
                            kind = MediaFrameKind.AUDIO,
                            trackName = audioInfo.name,
                            sourceTimestampUs = frame.timestampUs,
                            targetBuffering = targetBuffering,
                            trackEpoch = trackEpoch,
                            keyframe = frame.keyframe,
                            payloadBytes = frame.payload.size,
                        ),
                    )
                }
                renderer.submitFrame(frame.payload, frame.timestampUs)
            }

            try {
                statsTracker.onMediaTrackStarted(MediaFrameKind.AUDIO)
                audioTrack.frames.collect { frame ->
                    val eventContext = diagnosticsContext(MediaFrameKind.AUDIO, audioInfo.name)
                    pipelineBus.emit(
                        PipelineEvent.FrameArrived(
                            context = eventContext,
                            ptsUs = frame.timestampUs,
                            groupSequence = null,
                            frameIndex = null,
                            bytes = frame.payload.size,
                        ),
                    )
                    statsTracker.onMediaFrame(frame.toMoqFrame(), MediaFrameKind.AUDIO)
                    clock.nowMediaUs()?.takeIf { it > 0L }?.let(timeline::onPlaybackPosition)
                    when (val decision = timeline.onIngest(frame.toIngestEvent(trackEpoch, eventContext.timestampNanos))) {
                        is TimelineDecision.Admit -> submit(decision.frame.mediaFrame)
                        is TimelineDecision.Drop -> emitTimelineDrop(eventContext, decision)
                        is TimelineDecision.Reset -> {
                            executeTimelineReset(
                                kind = MediaFrameKind.AUDIO,
                                context = eventContext,
                                reset = decision,
                                flushedFrames = 0,
                                resetExecutor = {
                                    renderer.flush(decision.reason, decision.gapUs)
                                },
                            )
                            decision.resumeFrom?.mediaFrame?.let(::submit)
                        }
                        is TimelineDecision.End -> Unit
                    }
                }

                statsTracker.emitSubscribeEnd(MediaFrameKind.AUDIO, audioInfo.name, trackEpoch)
                emitTransportClosed(MediaFrameKind.AUDIO, audioInfo.name, error = null)
            } catch (_: CancellationException) {
                Log.d(TAG, "Audio ingest cancelled")
                emitTransportClosed(MediaFrameKind.AUDIO, audioInfo.name, error = null)
            } catch (e: Exception) {
                Log.e(TAG, "Audio ingest error", e)
                statsTracker.emitSubscribeError(
                    MediaFrameKind.AUDIO,
                    audioInfo.name,
                    e.message ?: "Unknown error",
                    trackEpoch,
                )
                emitTransportClosed(MediaFrameKind.AUDIO, audioInfo.name, e)
            } finally {
                audioTrack.close()
            }
        }
    }

    private fun launchVideoIngestJob(
        videoInfo: VideoTrackInfo,
        track: VideoRendererTrack,
        trackEpoch: Long,
        timeline: TrackTimeline,
    ): Job {
        Log.d(TAG, "Subscribing to video track '${videoInfo.name}'")
        val videoMediaTrack = broadcastOwner.subscribeMedia(
            MediaTrackRequest(track = videoInfo, targetBuffering = targetBuffering),
        )

        return scope.launch {
            var firstFrame = true
            fun submit(frame: MediaFrame, eventContext: PipelineContext) {
                val accepted = when (val result = track.insert(frame.payload, frame.timestampUs, frame.keyframe)) {
                    VideoTrackInsertResult.InvalidPayload -> {
                        emitBufferDrop(eventContext, frame, DropReason.INVALID_PAYLOAD)
                        false
                    }
                    is VideoTrackInsertResult.Buffered -> {
                        result.effects.forEach { effect ->
                            when (effect) {
                                is AdmissionEffect.Admitted -> pipelineBus.emit(
                                    PipelineEvent.FrameAdmitted(
                                        context = eventContext,
                                        ptsUs = effect.frame.timestampUs,
                                        bufferDepth = track.bufferDepth,
                                    ),
                                )
                                is AdmissionEffect.Rejected -> emitBufferDrop(
                                    context = eventContext,
                                    frame = effect.frame.mediaFrame,
                                    reason = effect.reason.toDropReason(),
                                )
                                is AdmissionEffect.EvictedGop -> {
                                    recordDroppedFrames(PipelineMediaKind.VIDEO, effect.count)
                                    pipelineBus.emit(
                                        PipelineEvent.FrameDropped(
                                            context = eventContext,
                                            stage = DropStage.BUFFER,
                                            reason = DropReason.BACKLOG_OVERFLOW,
                                            groupSequence = effect.groupSequence,
                                            count = effect.count,
                                            bytes = effect.bytes,
                                        ),
                                    )
                                }
                            }
                        }
                        result.effects.any { it is AdmissionEffect.Admitted }
                    }
                }

                if (accepted && firstFrame) {
                    firstFrame = false
                    Log.d(TAG, "First video frame accepted track='${videoInfo.name}' epoch=$trackEpoch")
                    statsTracker.emitTrackReady(
                        TrackReadyContext(
                            kind = MediaFrameKind.VIDEO,
                            trackName = videoInfo.name,
                            sourceTimestampUs = frame.timestampUs,
                            targetBuffering = targetBuffering,
                            trackEpoch = trackEpoch,
                            keyframe = frame.keyframe,
                            payloadBytes = frame.payload.size,
                        ),
                    )
                }
            }

            try {
                statsTracker.onMediaTrackStarted(MediaFrameKind.VIDEO)
                videoMediaTrack.frames.collect { frame ->
                    val eventContext = diagnosticsContext(MediaFrameKind.VIDEO, videoInfo.name)
                    pipelineBus.emit(
                        PipelineEvent.FrameArrived(
                            context = eventContext,
                            ptsUs = frame.timestampUs,
                            groupSequence = null,
                            frameIndex = null,
                            bytes = frame.payload.size,
                        ),
                    )
                    statsTracker.onMediaFrame(frame.toMoqFrame(), MediaFrameKind.VIDEO)
                    videoPlaybackPositionUs()?.let(timeline::onPlaybackPosition)
                    when (val decision = timeline.onIngest(frame.toIngestEvent(trackEpoch, eventContext.timestampNanos))) {
                        is TimelineDecision.Admit -> submit(decision.frame.mediaFrame, eventContext)
                        is TimelineDecision.Drop -> emitTimelineDrop(eventContext, decision)
                        is TimelineDecision.Reset -> {
                            val flushedFrames = track.bufferDepth.frames
                            executeTimelineReset(
                                kind = MediaFrameKind.VIDEO,
                                context = eventContext,
                                reset = decision,
                                flushedFrames = flushedFrames,
                                resetExecutor = {
                                    videoRenderer?.resetForTimeline(
                                        track = track,
                                        reason = decision.reason,
                                        gapUs = decision.gapUs,
                                    )
                                },
                            )
                            decision.resumeFrom?.mediaFrame?.let { submit(it, eventContext) }
                        }
                        is TimelineDecision.End -> Unit
                    }
                }

                statsTracker.emitSubscribeEnd(MediaFrameKind.VIDEO, videoInfo.name, trackEpoch)
                emitTransportClosed(MediaFrameKind.VIDEO, videoInfo.name, error = null)
            } catch (_: CancellationException) {
                Log.d(TAG, "Video ingest cancelled")
                emitTransportClosed(MediaFrameKind.VIDEO, videoInfo.name, error = null)
            } catch (e: Exception) {
                Log.e(TAG, "Video ingest error", e)
                statsTracker.emitSubscribeError(
                    MediaFrameKind.VIDEO,
                    videoInfo.name,
                    e.message ?: "Unknown error",
                    trackEpoch,
                )
                emitTransportClosed(MediaFrameKind.VIDEO, videoInfo.name, e)
            } finally {
                videoMediaTrack.close()
            }
        }
    }

    private fun restartCoordinator() {
        coordinatorJob?.cancel()
        val jobs = listOfNotNull(audioIngestJob, videoIngestJobs.active)
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

    private fun handleAudioRendererError(error: Throwable) {
        if (audioRenderer == null) return
        Log.e(TAG, "Audio renderer fatal error; terminating playback", error)
        val trackName = selectedAudioTrack?.name ?: "audio"
        statsTracker.emitDecodeError(MediaFrameKind.AUDIO, trackName, error.message ?: "Unknown error")
        onFatalError(error)
    }

    private fun stopVideo() {
        coordinatorJob?.cancel()
        coordinatorJob = null

        videoIngestJobs.close()

        videoRenderer?.stop()
        videoRenderer = null
        restartCoordinator()
    }

    private fun createTimeline(): TrackTimeline = TrackTimeline(
        policy = PipelinePolicies.timeline.copy(
            targetLatencyUs = targetBuffering.toMicrosecondsLongClamped(),
        ),
        timeSource = MonotonicTimeSource,
    )

    private fun updateTimelinePlaybackPositions(hasAudio: Boolean) {
        val playbackUs = clock.nowMediaUs()?.takeIf { it > 0L } ?: return
        audioTimeline?.onPlaybackPosition(playbackUs)
        val videoPlaybackUs = if (hasAudio) {
            timestampMapper.videoTimeUsOrNull(
                audioTimeUs = playbackUs,
                thresholdUs = TIMELINE_DOMAIN_TOLERANCE_US,
            )
        } else {
            playbackUs
        }
        videoPlaybackUs?.let { videoRenderer?.activeTimeline?.onPlaybackPosition(it) }
    }

    private fun videoPlaybackPositionUs(): Long? {
        val playbackUs = clock.nowMediaUs()?.takeIf { it > 0L } ?: return null
        return if (audioRenderer != null) {
            timestampMapper.videoTimeUsOrNull(
                audioTimeUs = playbackUs,
                thresholdUs = TIMELINE_DOMAIN_TOLERANCE_US,
            )
        } else {
            playbackUs
        }
    }

    private fun executeTimelineReset(
        kind: MediaFrameKind,
        context: PipelineContext,
        reset: TimelineDecision.Reset,
        flushedFrames: Int,
        resetExecutor: () -> Unit,
    ) {
        Log.d(TAG, "${kind.name.lowercase()} timeline reset reason=${reset.reason} gap=${reset.gapUs}us")
        resetExecutor()
        reset.gapUs?.let { statsTracker.onFrameDiscontinuity(kind, it) }
        pipelineBus.emit(
            PipelineEvent.Discontinuity(
                context = context,
                epoch = reset.epoch,
                reason = reset.reason.toDiscontinuityReason(),
            ),
        )
        if (flushedFrames > 0) {
            recordDroppedFrames(context.mediaKind, flushedFrames)
            pipelineBus.emit(
                PipelineEvent.FrameDropped(
                    context = context,
                    stage = DropStage.TIMELINE,
                    reason = reset.reason.toDropReason(),
                    count = flushedFrames,
                ),
            )
        }
    }

    private fun emitTimelineDrop(context: PipelineContext, decision: TimelineDecision.Drop) {
        if (decision.frame != null) recordDroppedFrames(context.mediaKind, 1)
        pipelineBus.emit(
            PipelineEvent.FrameDropped(
                context = context,
                stage = DropStage.TIMELINE,
                reason = decision.reason.toDropReason(),
                ptsUs = decision.frame?.timestampUs,
                groupSequence = decision.frame?.groupSequence,
                count = decision.groupRange?.countClampedToInt() ?: 1,
                bytes = decision.frame?.sizeBytes?.toLong() ?: 0L,
            ),
        )
    }

    private fun emitBufferDrop(context: PipelineContext, frame: MediaFrame, reason: DropReason) {
        recordDroppedFrames(context.mediaKind, 1)
        pipelineBus.emit(
            PipelineEvent.FrameDropped(
                context = context,
                stage = DropStage.BUFFER,
                reason = reason,
                ptsUs = frame.timestampUs,
                bytes = frame.payload.size.toLong(),
            ),
        )
    }

    private fun AdmissionRejectReason.toDropReason(): DropReason = when (this) {
        AdmissionRejectReason.WAITING_FOR_KEYFRAME -> DropReason.WAITING_FOR_KEYFRAME
        AdmissionRejectReason.FRAME_TOO_LARGE -> DropReason.BACKLOG_OVERFLOW
        AdmissionRejectReason.OLD_EPOCH,
        AdmissionRejectReason.UNEXPECTED_EPOCH -> DropReason.PUBLISHER_REWIND
        AdmissionRejectReason.DUPLICATE -> DropReason.COVERED
    }

    private fun recordDroppedFrames(kind: PipelineMediaKind, count: Int) {
        when (kind) {
            PipelineMediaKind.AUDIO -> statsTracker.recordAudioFramesDropped(count)
            PipelineMediaKind.VIDEO -> statsTracker.recordVideoFrameDropped(count)
        }
    }

    private fun TimelineDropReason.toDropReason(): DropReason = when (this) {
        TimelineDropReason.STALE_VS_PLAYBACK -> DropReason.STALE_VS_PLAYBACK
        TimelineDropReason.LATENCY_BUDGET_SKIP -> DropReason.LATENCY_BUDGET_SKIP
        TimelineDropReason.NETWORK_EVICTED -> DropReason.NETWORK_EVICTED
        TimelineDropReason.COVERED -> DropReason.COVERED
        TimelineDropReason.REWIND -> DropReason.PUBLISHER_REWIND
        TimelineDropReason.MISSING_SEQUENCE -> DropReason.MISSING_SEQUENCE
    }

    private fun TimelineResetReason.toDropReason(): DropReason = when (this) {
        TimelineResetReason.PUBLISHER_REWIND -> DropReason.PUBLISHER_REWIND
        TimelineResetReason.TIMESTAMP_GAP -> DropReason.TIMESTAMP_GAP_RESET
        TimelineResetReason.DOWNSTREAM_RECOVERY -> DropReason.RESET_FLUSH
    }

    private fun TimelineResetReason.toDiscontinuityReason(): DiscontinuityReason = when (this) {
        TimelineResetReason.PUBLISHER_REWIND -> DiscontinuityReason.PUBLISHER_REWIND
        TimelineResetReason.TIMESTAMP_GAP,
        TimelineResetReason.DOWNSTREAM_RECOVERY -> DiscontinuityReason.LOCAL_RESET
    }

    private fun LongRange.countClampedToInt(): Int {
        if (isEmpty()) return 0
        val distance = try {
            Math.subtractExact(last, first)
        } catch (_: ArithmeticException) {
            return Int.MAX_VALUE
        }
        return if (distance >= Int.MAX_VALUE.toLong()) Int.MAX_VALUE else distance.toInt() + 1
    }

    private fun diagnosticsContext(kind: MediaFrameKind, trackName: String): PipelineContext =
        PipelineContext(
            trackId = trackName,
            mediaKind = when (kind) {
                MediaFrameKind.AUDIO -> PipelineMediaKind.AUDIO
                MediaFrameKind.VIDEO -> PipelineMediaKind.VIDEO
            },
            timestampNanos = System.nanoTime(),
        )

    private fun emitTransportClosed(kind: MediaFrameKind, trackName: String, error: Throwable?) {
        pipelineBus.emit(
            PipelineEvent.TransportClosed(
                context = diagnosticsContext(kind, trackName),
                error = error?.let {
                    PipelineError(
                        code = it::class.java.simpleName.ifEmpty { "UnknownError" },
                        message = it.message ?: it.toString(),
                    )
                },
            ),
        )
    }
}

private fun MediaFrame.toMoqFrame(): MoqFrame =
    MoqFrame(
        payload = payload,
        timestampUs = timestampUs.coerceAtLeast(0L).toULong(),
        keyframe = keyframe,
    )

private fun MediaFrame.toIngestEvent(epoch: Long, arrivalNanos: Long): IngestEvent.Frame =
    IngestEvent.Frame(
        frame = TimedFrame(
            mediaFrame = this,
            epoch = epoch,
        ),
        arrivalNanos = arrivalNanos,
    )
