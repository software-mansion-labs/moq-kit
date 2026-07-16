package com.swmansion.moqkit.subscribe.internal.playback

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.subscribe.DecoderFlushReason
import com.swmansion.moqkit.subscribe.DropReason
import com.swmansion.moqkit.subscribe.DropStage
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.RetargetDecision
import com.swmansion.moqkit.subscribe.RecoveryStep
import com.swmansion.moqkit.subscribe.SwitchPhase
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.DiscontinuityReason
import com.swmansion.moqkit.subscribe.internal.pipeline.DecodedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEventObserver
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryExecutor
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderRecoveryResult
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderSupervisor
import com.swmansion.moqkit.subscribe.internal.pipeline.MonotonicTimeSource
import com.swmansion.moqkit.subscribe.internal.pipeline.DriverKind
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelinePolicies
import com.swmansion.moqkit.subscribe.internal.pipeline.PlaybackClock
import com.swmansion.moqkit.subscribe.internal.pipeline.RenderController
import com.swmansion.moqkit.subscribe.internal.pipeline.RenderExecution
import com.swmansion.moqkit.subscribe.internal.pipeline.RenderScheduler
import com.swmansion.moqkit.subscribe.internal.pipeline.RenditionSwitchController
import com.swmansion.moqkit.subscribe.internal.pipeline.SwitchDecision
import com.swmansion.moqkit.subscribe.internal.pipeline.SwitchState
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TimestampDomainMapper
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineResetReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "VideoRenderer"

/**
 * Orchestrates FrameBuffer-backed tracks + VideoDecoder for real-time video rendering.
 *
 * Supports seamless rendition switching via an active + pending track model:
 * - The active track feeds the decoder continuously.
 * - A pending track accumulates incoming frames in the background.
 * - [tryFeedDecoder] runs a [SwapPhase] state machine: discards stale pending frames,
 *   waits for a viable keyframe, then either cuts in seamlessly (no decoder restart)
 *   when the active track reaches that PTS, or swaps immediately (flush-and-swap)
 *   when the pending track is too far behind.
 *
 * ## Thread model
 * A single [HandlerThread] is owned by this class and shared across decoder swaps.
 * - **IO thread**: [VideoRendererTrack.insert] — thread-safe inside the track.
 * - **HandlerThread**: all decoder interaction — [tryFeedDecoder], [onDecodedFrame],
 *   [queuedFramesByPts], swap state machine. No locks needed for these.
 * - **Any thread**: [setPendingTrack] — posts to HandlerThread.
 * - **Caller thread**: lifecycle only — [start], [stop].
 */
internal class VideoRenderer(
    @Volatile private var activeTrack: VideoRendererTrack,
    @Volatile private var outputSurface: Surface,
    private val clock: PlaybackClock,
    private val timestampMapper: TimestampDomainMapper? = null,
    private val metrics: PlaybackStatsTracker? = null,
    pipelineBus: PipelineBus? = null,
    private val onError: (Throwable) -> Unit = {},
) {
    private data class QueuedFrameMetadata(
        val trackName: String,
        val queuedAtNs: Long,
        val playable: Boolean,
        val frontFrameIntervalUs: Long?,
    )

    private var pendingTrack: VideoRendererTrack? = null
    private val telemetry = RendererTelemetry(PipelineMediaKind.VIDEO, metrics, pipelineBus)
    private val switchPolicy = PipelinePolicies.switch
    private val switchController = RenditionSwitchController(switchPolicy)
    private var onTrackActivated: (() -> Unit)? = null
    private var onTrackAborted: (() -> Unit)? = null

    @Volatile
    var hasPendingTrack: Boolean = false
        private set

    @Volatile
    private var failed = false

    // HandlerThread (persistent across decoder swaps)

    private val handlerThread = HandlerThread("VideoRenderer").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val stallObservation = pipelineBus?.observe(::onPipelineEvent)
    private var clockStallTrackId: String? = null
    private val decoderScope = CoroutineScope(
        SupervisorJob() + handler.asCoroutineDispatcher("VideoRendererDecoder"),
    )
    private val decoderEventObserver = DecoderEventObserver<VideoDecoder>(
        scope = decoderScope,
        onEvent = ::onDecoderEvent,
    )
    private val renderController = RenderController(
        scheduler = RenderScheduler(PipelinePolicies.render, clock),
        sink = AndroidVideoRenderSink(),
    )

    // Decoder state (only accessed on HandlerThread)

    private val decoderRecovery = DecoderRecoveryExecutor(
        supervisor = DecoderSupervisor(PipelinePolicies.recovery, MonotonicTimeSource),
        createSession = ::createStartedDecoder,
        onRecovery = { telemetry.decoderRecovery(activeTrack.trackName, it) },
    )
    private val decoder: VideoDecoder?
        get() = decoderRecovery.currentSession
    private val queuedFramesByPts = HashMap<Long, QueuedFrameMetadata>()
    private val heldRenderCallbacks = mutableSetOf<Runnable>()

    /** PTS of the most recently fed frame to MediaCodec (used by swap state machine). */
    private var lastFedPtsUs: Long = 0L

    /** After a CuttingIn swap, frames with PTS <= this value are decoded but not displayed
     *  to avoid showing duplicate frames from the overlap between old and new rendition. */
    private var noDisplayBeforePts: Long = Long.MIN_VALUE
    private var awaitingKeyframeTimeout: Runnable? = null
    private var timelineStarted = false
    private var lastKnownClockTimeUs: Long = 0L

    /** CSD bytes to queue as BUFFER_FLAG_CODEC_CONFIG before feeding the new rendition's
     *  first frame, so the decoder can handle adaptive resolution changes. */
    private var pendingCsd: ByteArray? = null
    private var isPlaybackStartEventArmed = true

    companion object {
        private const val PTS_CORRECTION_THRESHOLD_US = 2_000_000L
        private const val HANDLER_SYNC_TIMEOUT_MS = 2_000L
    }

    val bufferFill: Duration get() = activeTrack.depth
    val activeTimeline get() = activeTrack.timeline

    // MARK: - Lifecycle

    fun start() {
        Log.d(TAG, "Starting")

        activeTrack.setOnDataAvailable {
            postDecoderWork {
                if (activeTrack.isProcessorReady) {
                    maybeInitDecoder()
                }
                tryFeedDecoder()
            }
        }
        if (activeTrack.isProcessorReady) {
            postDecoderWork { maybeInitDecoder() }
        } else {
            Log.d(TAG, "Deferring decoder init until CSD is available")
        }

        Log.d(TAG, "VideoRenderer started")
    }

    private fun maybeInitDecoder() {
        if (decoder != null) return
        decoderRecovery.start()
    }

    private fun createStartedDecoder(): VideoDecoder {
        val format = activeTrack.getFormat()
            ?: throw IllegalStateException("Cannot init decoder: format not ready")
        val session = VideoDecoder(
            format = format,
            surface = outputSurface,
            handler = handler,
        )
        observeDecoderEvents(session)
        try {
            session.start()
        } catch (error: Throwable) {
            decoderEventObserver.close()
            session.release()
            throw error
        }
        Log.d(TAG, "Decoder initialized: $format")
        return session
    }

    private fun observeDecoderEvents(session: VideoDecoder) {
        decoderEventObserver.observe(session)
    }

    private fun onDecoderEvent(session: VideoDecoder, event: DecoderEvent) {
        if (decoder != null && decoder !== session) return
        when (event) {
            DecoderEvent.InputAvailable -> tryFeedDecoder()
            is DecoderEvent.OutputReady -> onDecodedFrame(
                outputHandle = event.handle as VideoOutputHandle,
                timestampUs = event.timestampUs,
            )
            is DecoderEvent.Error -> recoverDecoder(event.throwable)
            DecoderEvent.Reconfigured -> Unit
        }
    }

    private fun recoverDecoder(error: Throwable) {
        if (failed) return
        val droppedFrames = resetForDecoderRecovery()
        when (val result = decoderRecovery.recover(error)) {
            is DecoderRecoveryResult.Recovered -> {
                Log.w(TAG, "Decoder recovered via ${result.attempt.step}", error)
                observeDecoderEvents(result.session)
                if (result.attempt.step == RecoveryStep.FLUSH) {
                    telemetry.decoderFlushed(
                        trackName = activeTrack.trackName,
                        reason = DecoderFlushReason.DECODER_RECOVERY,
                        trigger = result.attempt.trigger,
                        droppedFrames = droppedFrames,
                    )
                }
                tryFeedDecoder()
            }
            is DecoderRecoveryResult.Failed -> {
                decoderEventObserver.close()
                handleFatalError(result.error)
            }
        }
    }

    private fun resetForDecoderRecovery(): Int {
        val reset = activeTrack.timeline.requestReset()
        val flushedFrames = activeTrack.flush() + queuedFramesByPts.size + heldRenderCallbacks.size
        resetDecoderPipelineState()
        isPlaybackStartEventArmed = true
        telemetry.discontinuity(activeTrack.trackName, reset.epoch, DiscontinuityReason.LOCAL_RESET)
        telemetry.frameDropped(
            trackName = activeTrack.trackName,
            stage = DropStage.DECODER,
            reason = DropReason.DECODER_RECOVERY_FLUSH,
            count = flushedFrames,
        )
        return flushedFrames
    }

    private fun resetDecoderPipelineState() {
        cancelHeldRenders()
        queuedFramesByPts.clear()
        noDisplayBeforePts = Long.MIN_VALUE
        lastFedPtsUs = 0L
        timelineStarted = false
        lastKnownClockTimeUs = 0L
        clock.resetVideo()
    }

    private fun cancelHeldRenders() {
        heldRenderCallbacks.forEach(handler::removeCallbacks)
        heldRenderCallbacks.clear()
    }

    private fun onPipelineEvent(event: PipelineEvent) {
        if (event.context.mediaKind != PipelineMediaKind.VIDEO) return
        when (event) {
            is PipelineEvent.StallStarted -> handler.post {
                runDecoderWorkSafely { beginVideoStall(event.context.trackId) }
            }
            is PipelineEvent.StallEnded -> handler.post {
                runDecoderWorkSafely { endVideoStall(event.context.trackId) }
            }
            else -> Unit
        }
    }

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")

        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        activeTrack.flush()
        handler.post {
            awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
            awaitingKeyframeTimeout = null
            noDisplayBeforePts = 0L
            pendingCsd = null
            pendingTrack = null
            switchController.complete()
            onTrackActivated = null
            onTrackAborted = null
            timelineStarted = false
            lastKnownClockTimeUs = 0L
            clock.resetVideo()
            cancelHeldRenders()
            queuedFramesByPts.clear()
            decoderEventObserver.close()
            decoderRecovery.release()
            decoderScope.cancel()
            stallObservation?.close()
            handlerThread.quitSafely()

            Log.d(TAG, "VideoRenderer stopped")
        }
    }

    fun updateTargetBuffering(latency: Duration) {
        postDecoderWork {
            val activeBecamePlayable = activeTrack.updateTargetBuffering(latency)
            pendingTrack?.updateTargetBuffering(latency)
            if (clock.masterDriverKind == DriverKind.VIDEO && timelineStarted) {
                syncClockToTargetLatency()
            }
            if (clock.masterDriverKind == DriverKind.VIDEO || activeBecamePlayable) {
                tryFeedDecoder()
            }
        }
    }

    /** Executes a reset selected by the track timeline; this method owns decoder-side effects. */
    fun resetForTimeline(
        track: VideoRendererTrack,
        reason: TimelineResetReason,
        gapUs: Long?,
    ) {
        val bufferedFrames = track.flush()
        if (track === activeTrack) {
            clock.resetVideo()
        }
        postDecoderWork {
            when (track) {
                activeTrack -> {
                    val decoderFrames = queuedFramesByPts.size + heldRenderCallbacks.size
                    telemetry.frameDropped(
                        trackName = activeTrack.trackName,
                        stage = DropStage.DECODER,
                        reason = DropReason.RESET_FLUSH,
                        count = decoderFrames,
                    )
                    decoder?.let { session ->
                        flushDecoder(
                            session = session,
                            reason = DecoderFlushReason.TIMELINE_RESET,
                            trigger = timelineResetTrigger(reason, gapUs),
                            droppedFrames = bufferedFrames + decoderFrames,
                        )
                    }
                    resetDecoderPipelineState()
                }

                pendingTrack -> track.setBufferState(VideoBufferState.PENDING)
            }
        }
    }

    /**
     * Retarget decoder output to [surface]. If the decoder is not initialized yet, only updates
     * the stored surface so the next decoder creation binds to the new target.
     */
    fun setSurface(surface: Surface) {
        if (outputSurface == surface) {
            return
        }

        runOnHandlerSync {
            decoder?.setOutputSurface(surface)
            outputSurface = surface
        }
    }

    /**
     * Install a pending track. The switch state machine in [tryFeedDecoder] will
     * decide between cut-in and flush-and-swap, then call [performSwap].
     * [onActivated] is called on the HandlerThread at the moment of the swap. [onAborted] is
     * called when the pending track fails to produce a viable keyframe before the timeout.
     */
    fun setPendingTrack(
        track: VideoRendererTrack,
        onActivated: (() -> Unit)?,
        onAborted: (() -> Unit)?,
    ) {
        hasPendingTrack = true
        telemetry.switchProgress(track.trackName, SwitchPhase.PREPARING)
        handler.post {
            pendingTrack?.setOnDataAvailable(null)
            noDisplayBeforePts = 0L
            track.setBufferState(VideoBufferState.PENDING)
            pendingTrack = track
            switchController.begin(track.trackName)
            onTrackActivated = onActivated
            onTrackAborted = onAborted
            track.setOnDataAvailable {
                postDecoderWork {
                    tryFeedDecoder()
                }
            }

            awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
            val timeout = Runnable {
                awaitingKeyframeTimeout = null
                if (switchController.onTimeout() is SwitchDecision.Abort) {
                    Log.w(TAG, "Rendition switch timed out; keeping active track")
                    track.setOnDataAvailable(null)
                    pendingTrack = null
                    hasPendingTrack = false
                    onTrackActivated = null
                    val aborted = onTrackAborted
                    onTrackAborted = null
                    telemetry.switchProgress(track.trackName, SwitchPhase.ABORTED)
                    aborted?.invoke()
                }
            }
            awaitingKeyframeTimeout = timeout
            handler.postDelayed(timeout, switchPolicy.keyframeTimeoutUs / 1_000L)
        }
    }

    // MARK: - Drain loop + swap state machine (HandlerThread only)

    private fun tryFeedDecoder() {
        if (!prepareClockForDrain()) {
            return
        }
        maybePromotePendingTrack()
        maybeApplyPendingCodecData()

        // --- Drain active track ---
        val activeDecoder = decoder ?: return
        while (activeDecoder.canQueueInput) {
            if (activeTrack.peekNextTimestampUs() == null) {
                return
            }

            val frontFrameIntervalUs = activeTrack.frontFrameIntervalUs
            val (entry, playable) = activeTrack.dequeue()
            if (entry == null) {
                return
            }
            telemetry.bufferDepth(activeTrack.trackName, activeTrack.bufferDepth)

            lastFedPtsUs = entry.item.timestampUs
            val queuedAtNs = System.nanoTime()
            val frame = TimedFrame(
                mediaFrame = MediaFrame(
                    payload = entry.item.payload,
                    timestampUs = entry.item.timestampUs,
                    keyframe = entry.item.isKeyframe,
                ),
                epoch = activeTrack.trackEpoch,
            )
            if (activeDecoder.queueInput(frame)) {
                queuedFramesByPts[entry.item.timestampUs] = QueuedFrameMetadata(
                    trackName = activeTrack.trackName,
                    queuedAtNs = queuedAtNs,
                    playable = playable,
                    frontFrameIntervalUs = frontFrameIntervalUs,
                )
                metrics?.recordVideoDecodeBufferSubmitted(activeTrack.trackName)
                telemetry.decoderInputQueued(
                    trackName = activeTrack.trackName,
                    ptsUs = entry.item.timestampUs,
                    timestampNanos = queuedAtNs,
                )
            } else {
                telemetry.frameDropped(
                    trackName = activeTrack.trackName,
                    stage = DropStage.DECODER,
                    reason = DropReason.DECODER_INPUT_BACKPRESSURE,
                    ptsUs = entry.item.timestampUs,
                    bytes = entry.item.payload.size.toLong(),
                    timestampNanos = queuedAtNs,
                )
            }
        }
    }

    private fun beginVideoStall(trackId: String) {
        if (trackId != activeTrack.trackName || clockStallTrackId != null) return
        clockStallTrackId = trackId
        lastKnownClockTimeUs = currentPlaybackTimeUs()
        if (clock.masterDriverKind == DriverKind.VIDEO && timelineStarted) {
            clock.pauseVideo()
        }
    }

    private fun endVideoStall(trackId: String) {
        if (clockStallTrackId != trackId) return
        clockStallTrackId = null
        if (clock.masterDriverKind == DriverKind.VIDEO && timelineStarted) {
            clock.resumeVideo()
        }
    }

    private fun maybePromotePendingTrack() {
        val pending = pendingTrack ?: return
        if (switchController.state is SwitchState.Preparing) {
            var discardedFrames = 0
            while (true) {
                val front = pending.peekFront() ?: break
                if (front.second) break
                if (!switchController.shouldDiscardPendingDelta(lastFedPtsUs, front.first)) break
                if (pending.discardFront()) discardedFrames++
            }
            recordRenditionSwitchDrops(pending.trackName, discardedFrames)
            pending.firstKeyframePts?.let { keyframePtsUs ->
                awaitingKeyframeTimeout?.let(handler::removeCallbacks)
                awaitingKeyframeTimeout = null
                when (switchController.onKeyframeAvailable(lastFedPtsUs, keyframePtsUs)) {
                    SwitchDecision.FlushSwap -> telemetry.switchProgress(
                        pending.trackName,
                        SwitchPhase.FLUSH_SWAP,
                    )
                    SwitchDecision.Wait -> telemetry.switchProgress(pending.trackName, SwitchPhase.CUT_IN)
                    is SwitchDecision.Abort,
                    is SwitchDecision.CutIn -> Unit
                }
            }
        }

        val cuttingIn = switchController.state as? SwitchState.CuttingIn
        if (cuttingIn != null) {
            recordRenditionSwitchDrops(
                trackName = pending.trackName,
                count = pending.discardNonKeyframesBeforePts(cuttingIn.keyframePtsUs),
            )
        }

        when (switchController.onActiveProgress(lastFedPtsUs)) {
            is SwitchDecision.CutIn -> {
                noDisplayBeforePts = lastFedPtsUs
                pending.setBufferState(VideoBufferState.PLAYING)
                performSwap(pending)
                switchController.complete()
            }
            SwitchDecision.FlushSwap -> {
                pending.setBufferState(VideoBufferState.PLAYING)
                performSwap(pending, hardFlush = true)
                switchController.complete()
            }
            is SwitchDecision.Abort,
            SwitchDecision.Wait -> Unit
        }
    }

    private fun maybeApplyPendingCodecData() {
        val csd = pendingCsd ?: return
        val dec = decoder ?: return
        if (!dec.queueCodecConfig(csd)) return
        Log.d(TAG, "Queued CSD config buffer (${csd.size}B) for adaptive switch")
        pendingCsd = null
    }

    /**
     * Promotes [newTrack] to active. Must be called on HandlerThread.
     *
     * The decoder is **reused** across swaps (adaptive playback). The same MediaCodec instance
     * handles resolution changes transparently as long as the codec (MIME type) is unchanged.
     * Throws if the codec changes — the caller must tear down and re-create [VideoRenderer] instead.
     *
     * @param hardFlush When true, flushes and restarts the decoder to discard stale queued state
     *                  (used for the FlushAndSwap path where the pending track is far behind).
     *                  When false (CuttingIn / emergency swap), the decoder keeps running and
     *                  input buffer indices remain valid.
     */
    private fun performSwap(newTrack: VideoRendererTrack, hardFlush: Boolean = false) {
        Log.d(TAG, "VideoRenderer: swapping to pending track (hardFlush=$hardFlush)")

        AdaptiveVideoCodec.requireCompatible(activeTrack.getFormat(), newTrack.getFormat())
        // Rendition switching assumes all video tracks use the same source timestamp domain.
        // TimestampDomainMapper compares the active audio/video timeline domains before
        // scheduling; rendition tracks are still expected to share one video source domain.

        val currentDecoder = decoder
        if (currentDecoder != null) {
            if (hardFlush) {
                val droppedFrames = queuedFramesByPts.size + heldRenderCallbacks.size
                telemetry.frameDropped(
                    trackName = activeTrack.trackName,
                    stage = DropStage.DECODER,
                    reason = DropReason.RENDITION_SWITCH,
                    count = droppedFrames,
                )
                flushDecoder(
                    session = currentDecoder,
                    reason = DecoderFlushReason.RENDITION_SWITCH,
                    trigger = "hard swap to ${newTrack.trackName}",
                    droppedFrames = droppedFrames,
                )
                cancelHeldRenders()
                queuedFramesByPts.clear()
            }
            // else: decoder keeps running and its input capacity remains valid
        } else {
            // Decoder not yet initialized (swap before first keyframe on active track).
            if (newTrack.getFormat() == null) {
                Log.d(TAG, "performSwap: format not ready, deferring decoder init")
            }
        }

        activeTrack.setOnDataAvailable(null)
        recordRenditionSwitchDrops(
            trackName = activeTrack.trackName,
            count = activeTrack.flush(),
        )
        activeTrack = newTrack
        isPlaybackStartEventArmed = true
        metrics?.resetVideoDecodeStats(newTrack.trackName)
        pendingCsd = AdaptiveVideoCodec.codecData(newTrack.getFormat())
        pendingTrack = null
        hasPendingTrack = false

        if (decoder == null && activeTrack.isProcessorReady) {
            maybeInitDecoder()
        }

        newTrack.setOnDataAvailable {
            postDecoderWork {
                if (activeTrack.isProcessorReady) {
                    maybeInitDecoder()
                }
                tryFeedDecoder()
            }
        }

        onTrackActivated?.invoke()
        onTrackActivated = null
        onTrackAborted = null
        telemetry.switchProgress(newTrack.trackName, SwitchPhase.STEADY)
    }

    // Decoded frame handling (HandlerThread only)

    private fun onDecodedFrame(outputHandle: VideoOutputHandle, timestampUs: Long) {
        val outputAtNs = System.nanoTime()
        val metadata = queuedFramesByPts.remove(timestampUs)
        val diagnosticTrackName = metadata?.trackName ?: activeTrack.trackName
        telemetry.decoderOutputReady(
            trackName = diagnosticTrackName,
            ptsUs = timestampUs,
            timestampNanos = outputAtNs,
        )
        if (metadata != null) {
            metrics?.recordVideoDecodeTime(
                trackName = metadata.trackName,
                durationNs = outputAtNs - metadata.queuedAtNs,
                outputAtNs = outputAtNs,
            )
        }
        val playable = metadata?.playable ?: true
        val displayTimestampUs = audioTime(timestampUs)
        // After a CuttingIn swap, suppress display of frames that overlap with the
        // previous rendition. They are still decoded (needed as reference frames) but
        // not rendered, preventing duplicate-frame stutter.
        if (timestampUs <= noDisplayBeforePts) {
            outputHandle.session.dropOutput(outputHandle.index)
            telemetry.frameDropped(
                trackName = diagnosticTrackName,
                stage = DropStage.RENDERER,
                reason = DropReason.RENDITION_SWITCH,
                ptsUs = timestampUs,
                timestampNanos = outputAtNs,
            )
            if (timestampUs == noDisplayBeforePts) noDisplayBeforePts = Long.MIN_VALUE
            return
        }

        if (!playable) {
            outputHandle.session.dropOutput(outputHandle.index)
            telemetry.frameDropped(
                trackName = diagnosticTrackName,
                stage = DropStage.RENDERER,
                reason = DropReason.STALE_VS_PLAYBACK,
                ptsUs = timestampUs,
                timestampNanos = outputAtNs,
            )
            return
        }

        processDecodedFrame(
            sourceTimestampUs = timestampUs,
            displayTimestampUs = displayTimestampUs,
            outputHandle = outputHandle,
            metadata = metadata,
            trackName = diagnosticTrackName,
        )
    }

    private fun processDecodedFrame(
        sourceTimestampUs: Long,
        displayTimestampUs: Long,
        outputHandle: VideoOutputHandle,
        metadata: QueuedFrameMetadata?,
        trackName: String,
    ) {
        val nowNanos = System.nanoTime()
        val frame = DecodedFrame(
            ptsUs = displayTimestampUs,
            durationUs = metadata?.frontFrameIntervalUs,
            handle = outputHandle,
        )
        when (val execution = renderController.process(frame, nowNanos)) {
            is RenderExecution.DroppedLate -> {
                telemetry.frameDropped(
                    trackName = trackName,
                    stage = DropStage.RENDERER,
                    reason = DropReason.LATE_RENDER,
                    ptsUs = sourceTimestampUs,
                    timestampNanos = nowNanos,
                )
            }

            is RenderExecution.Held -> {
                lateinit var retry: Runnable
                retry = Runnable {
                    heldRenderCallbacks.remove(retry)
                    runDecoderWorkSafely {
                        processDecodedFrame(
                            sourceTimestampUs,
                            displayTimestampUs,
                            outputHandle,
                            metadata,
                            trackName,
                        )
                    }
                }
                heldRenderCallbacks += retry
                val delayMillis = (execution.recheckAfterUs / 1_000L).coerceIn(1L, 100L)
                handler.postDelayed(retry, delayMillis)
            }

            is RenderExecution.Rendered -> {
                if (!execution.confirmed) {
                    telemetry.frameDropped(
                        trackName = trackName,
                        stage = DropStage.DECODER,
                        reason = DropReason.DECODER_RECOVERY_FLUSH,
                        ptsUs = sourceTimestampUs,
                        timestampNanos = nowNanos,
                    )
                    return
                }

                metrics?.recordVideoFrameDisplayed()
                telemetry.frameRendered(
                    trackName = trackName,
                    ptsUs = sourceTimestampUs,
                    renderNanos = execution.renderNanos,
                    timestampNanos = nowNanos,
                )
                emitPlaybackStartIfArmed(
                    sourceTimestampUs = sourceTimestampUs,
                    presentationTimeUs = displayTimestampUs,
                    clockTimeUs = playbackTimeUsForScheduling() ?: displayTimestampUs,
                    buffer = activeTrack.depth,
                )
            }
        }
    }

    private fun emitPlaybackStartIfArmed(
        sourceTimestampUs: Long,
        presentationTimeUs: Long,
        clockTimeUs: Long,
        buffer: Duration,
    ) {
        if (!isPlaybackStartEventArmed) return
        isPlaybackStartEventArmed = false
        metrics?.videoPlaybackStarted(
            context = PlaybackStartContext(
                kind = MediaFrameKind.VIDEO,
                trackName = activeTrack.trackName,
                sourceTimestampUs = sourceTimestampUs,
                targetBuffering = activeTrack.targetBuffering,
                trackEpoch = activeTrack.trackEpoch,
            ),
            presentationTimeUs = presentationTimeUs,
            clockTimeUs = clockTimeUs,
            buffer = buffer,
        )
    }

    private fun runOnHandlerSync(block: () -> Unit) {
        if (Looper.myLooper() == handler.looper) {
            block()
            return
        }

        val failure = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        val posted = handler.post {
            try {
                block()
            } catch (t: Throwable) {
                failure.set(t)
            } finally {
                latch.countDown()
            }
        }
        if (!posted) {
            error("VideoRenderer handler is not accepting work")
        }
        if (!latch.await(HANDLER_SYNC_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            Log.e(TAG, "Timed out waiting ${HANDLER_SYNC_TIMEOUT_MS}ms for VideoRenderer thread")
            error("Timed out waiting for VideoRenderer thread")
        }

        failure.get()?.let { throw it }
    }

    private fun postDecoderWork(block: () -> Unit) {
        handler.post { runDecoderWorkSafely(block) }
    }

    private fun runDecoderWorkSafely(block: () -> Unit) {
        if (failed) {
            return
        }

        try {
            block()
        } catch (t: Throwable) {
            handleFatalError(t)
        }
    }

    private fun handleFatalError(error: Throwable) {
        if (failed) {
            return
        }

        failed = true
        Log.e(TAG, "VideoRenderer fatal error", error)
        cancelHeldRenders()
        queuedFramesByPts.clear()
        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        onError(error)
    }

    private fun prepareClockForDrain(): Boolean {
        val driverKind = clock.masterDriverKind
        if (!timelineStarted) {
            val started = startVideoClockIfReady()
            if (!started && driverKind == DriverKind.VIDEO) return false
        }
        if (driverKind == DriverKind.VIDEO) {
            syncClockToTargetLatency()
        }
        return true
    }

    private fun startVideoClockIfReady(): Boolean {
        if (activeTrack.state != VideoBufferState.PLAYING) return false
        val sourceStartUs = activeTrack.targetPlaybackPTS()
            ?: activeTrack.peekFront()?.first
            ?: return false
        val startUs = audioTime(sourceStartUs)
        timelineStarted = true
        lastKnownClockTimeUs = startUs
        clock.startVideoAt(startUs)
        val masterClock = clock.masterDriverKind
        Log.d(
            TAG,
            "Started video timeline masterClock=$masterClock sourceStartUs=$sourceStartUs " +
                "displayStartUs=$startUs " +
                "bufferFillMs=${activeTrack.depthMs}",
        )
        return true
    }

    private fun syncClockToTargetLatency() {
        if (clock.masterDriverKind != DriverKind.VIDEO) return
        val liveEdgeSourceUs = activeTrack.timeline.liveEdgeUs() ?: return
        clock.onLiveEdge(audioTime(liveEdgeSourceUs))
        val decision = clock.retarget(activeTrack.targetBuffering.toMicrosecondsLongClamped())
        if (decision != RetargetDecision.NoOp) {
            telemetry.clockRetarget(activeTrack.trackName, decision)
        }
    }

    private fun playbackTimeUsForScheduling(): Long? {
        if (clock.masterDriverKind == DriverKind.VIDEO) {
            return if (timelineStarted) currentPlaybackTimeUs() else null
        }
        return clock.nowMediaUs()?.takeIf { it > 0L }
    }

    private fun currentPlaybackTimeUs(): Long {
        val clockTimeUs = clock.nowMediaUs() ?: return lastKnownClockTimeUs
        if (clockTimeUs >= lastKnownClockTimeUs) {
            lastKnownClockTimeUs = clockTimeUs
            return clockTimeUs
        }
        return lastKnownClockTimeUs
    }

    private fun audioTime(videoTime: Long): Long =
        timestampMapper?.audioTimeUs(
            videoTimeUs = videoTime,
            thresholdUs = PTS_CORRECTION_THRESHOLD_US,
        ) ?: videoTime

    private fun recordRenditionSwitchDrops(trackName: String, count: Int) = telemetry.frameDropped(
        trackName = trackName,
        stage = DropStage.BUFFER,
        reason = DropReason.RENDITION_SWITCH,
        count = count,
    )

    private fun flushDecoder(
        session: VideoDecoder,
        reason: DecoderFlushReason,
        trigger: String,
        droppedFrames: Int,
    ) {
        decoderEventObserver.flush(session)
        telemetry.decoderFlushed(activeTrack.trackName, reason, trigger, droppedFrames)
    }
}
