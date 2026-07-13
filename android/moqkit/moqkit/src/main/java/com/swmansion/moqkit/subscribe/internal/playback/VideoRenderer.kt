package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "VideoRenderer"

internal fun advanceRenditionSwitchProgressUs(
    currentProgressUs: Long,
    submittedPtsUs: Long,
): Long = maxOf(currentProgressUs, submittedPtsUs)

/**
 * Orchestrates JitterBuffer + VideoDecoder for real-time video rendering.
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
 *   [parkedInputBuffers], [queuedFramesByPts], swap state machine. No locks needed for these.
 * - **Any thread**: [setPendingTrack] — posts to HandlerThread.
 * - **Caller thread**: lifecycle only — [start], [stop].
 */
internal class VideoRenderer(
    @Volatile private var activeTrack: VideoRendererTrack,
    @Volatile private var outputSurface: Surface,
    private val clock: MediaClock? = null,
    private val metrics: PlaybackStatsTracker? = null,
    private val onError: (Throwable) -> Unit = {},
) {
    // Pending-track swap state machine

    private sealed class TrackSwapPhase {
        object AwaitingKeyframe : TrackSwapPhase()
        data class CuttingIn(val keyframePts: Long) : TrackSwapPhase()
        object FlushAndSwap : TrackSwapPhase()
    }

    private data class QueuedFrameMetadata(
        val trackName: String,
        val queuedAtNs: Long,
        val playable: Boolean,
        val frontFrameIntervalUs: Long?,
    )

    private data class ScheduledFrameMetadata(
        val trackName: String,
        val trackEpoch: Long,
        val targetBuffering: Duration,
        val sourceTimestampUs: Long,
        val presentationTimeUs: Long,
        val clockTimeUs: Long,
        val buffer: Duration,
        val scheduledRenderTimeNs: Long,
        val frontFrameIntervalUs: Long?,
    )

    private var pendingTrack: VideoRendererTrack? = null
    private var trackSwapPhase: TrackSwapPhase? = null
    private var onTrackActivated: (() -> Unit)? = null

    @Volatile
    var hasPendingTrack: Boolean = false
        private set

    @Volatile
    private var failed = false

    // HandlerThread (persistent across decoder swaps)

    private val handlerThread = HandlerThread("VideoRenderer").apply { start() }
    private val handler = Handler(handlerThread.looper)

    // Decoder state (only accessed on HandlerThread)

    private var decoder: VideoDecoder? = null
    private var decoderGeneration = 0L
    private val parkedInputBuffers = ArrayDeque<Int>()
    private val queuedFramesByPts = TimestampedQueue<QueuedFrameMetadata>()
    private val scheduledFramesByPts = TimestampedQueue<ScheduledFrameMetadata>()
    private var delayedDrainToken: Any? = null
    private var pendingStallCheck: Runnable? = null
    private val stallHorizon = VideoStallHorizon()
    private val decoderRecoveryBudget = DecoderRecoveryBudget(
        maxRecoveries = MAX_DECODER_RECOVERIES_PER_WINDOW,
        windowNs = DECODER_RECOVERY_WINDOW_NS,
    )
    private var awaitingRecoveryKeyframe = false

    /** Maximum PTS fed to MediaCodec since the last hard timeline reset. */
    private var maxFedPtsUs: Long = 0L

    /** After a CuttingIn swap, frames with PTS <= this value are decoded but not displayed
     *  to avoid showing duplicate frames from the overlap between old and new rendition. */
    private var noDisplayBeforePts: Long = Long.MIN_VALUE
    private var awaitingKeyframeTimeout: Runnable? = null
    private var timelineStarted = clock?.isVideoDriven != true
    private var lastKnownClockTimeUs: Long = 0L

    /** CSD bytes to queue as BUFFER_FLAG_CODEC_CONFIG before feeding the new rendition's
     *  first frame, so the decoder can handle adaptive resolution changes. */
    private var pendingCsd: ByteArray? = null
    private var isPlaybackStartEventArmed = true
    private val usesReliableFrameRenderedCallbacks =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    companion object {
        private const val MAX_AHEAD_US = 500_000L
        private const val MAX_RENDER_SCHEDULE_NS = 500_000_000L
        private const val CUT_IN_WINDOW_US = 500_000L
        private const val FLUSH_THRESHOLD_US = 2_000_000L
        private const val AWAITING_KEYFRAME_TIMEOUT_MS = 5_000L
        private const val HANDLER_SYNC_TIMEOUT_MS = 2_000L
        private const val CLOCK_RETARGET_TOLERANCE_US = 20_000L
        private const val DECODER_RECOVERY_WINDOW_NS = 10_000_000_000L
        private const val MAX_DECODER_RECOVERIES_PER_WINDOW = 2
    }

    val bufferFill: Duration get() = activeTrack.depth

    // MARK: - Lifecycle

    fun start() {
        Log.d(TAG, "Starting")

        activeTrack.setOnDataAvailable {
            postDecoderWork {
                cancelPendingVideoStallCheck()
                if (activeTrack.isProcessorReady) {
                    maybeInitDecoder()
                }
                tryFeedDecoder()
                requestVideoStallCheck()
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

        val format = activeTrack.getFormat()
            ?: throw IllegalStateException("Cannot init decoder: format not ready")

        var newDecoder: VideoDecoder? = null
        try {
            val decoder = buildDecoder(format)
            newDecoder = decoder
            decoder.start()
        } catch (t: Throwable) {
            try {
                newDecoder?.release()
            } catch (_: Throwable) {
            }
            throw t
        }
        decoder = requireNotNull(newDecoder)
        awaitingRecoveryKeyframe = false

        Log.d(TAG, "Decoder initialized: $format")
    }

    private fun buildDecoder(format: android.media.MediaFormat): VideoDecoder {
        val generation = ++decoderGeneration
        return VideoDecoder(
            format = format,
            surface = outputSurface,
            handler = handler,
            onInputBufferAvailable = { index ->
                if (generation == decoderGeneration) {
                    parkedInputBuffers.addLast(index)
                    tryFeedDecoder()
                }
            },
            onOutputBufferAvailable = { bufferIndex, timestampUs ->
                if (generation == decoderGeneration) {
                    onDecodedFrame(bufferIndex, timestampUs)
                }
            },
            onFrameRendered = { timestampUs, renderTimeNs ->
                if (generation == decoderGeneration) {
                    onFrameRendered(timestampUs, renderTimeNs)
                }
            },
            onError = { error ->
                if (generation == decoderGeneration) {
                    runDecoderWorkSafely { recoverDecoder("MediaCodec error", error) }
                }
            },
        )
    }

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")

        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        activeTrack.flush()
        handler.post {
            delayedDrainToken?.let { handler.removeCallbacksAndMessages(it) }
            delayedDrainToken = null
            pendingStallCheck?.let { handler.removeCallbacks(it) }
            pendingStallCheck = null
            stallHorizon.reset()
            awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
            awaitingKeyframeTimeout = null
            noDisplayBeforePts = 0L
            pendingCsd = null
            pendingTrack = null
            trackSwapPhase = null
            timelineStarted = clock?.isVideoDriven != true
            lastKnownClockTimeUs = 0L
            if (clock?.isVideoDriven == true) {
                clock.reset()
            }
            parkedInputBuffers.clear()
            queuedFramesByPts.clear()
            scheduledFramesByPts.clear()
            decoderRecoveryBudget.clear()
            awaitingRecoveryKeyframe = false
            decoderGeneration++
            decoder?.release()
            decoder = null
            handlerThread.quitSafely()

            Log.d(TAG, "VideoRenderer stopped")
        }
    }

    fun updateTargetBuffering(latency: Duration) {
        postDecoderWork {
            val activeBecamePlayable = activeTrack.updateTargetBuffering(latency)
            pendingTrack?.updateTargetBuffering(latency)
            val canDrain = if (clock?.isVideoDriven == true && timelineStarted) {
                syncClockToTargetLatency()
            } else {
                true
            }
            if (canDrain && (clock?.isVideoDriven == true || activeBecamePlayable)) {
                tryFeedDecoder()
            }
        }
    }

    /**
     * Atomically abandons the active video generation. The track is flushed synchronously so
     * ingest cannot append more deltas to the old GOP; codec state is then reset ahead of the
     * next data-available callback posted by the ingest thread.
     */
    fun resetForDiscontinuity(track: VideoRendererTrack, reason: String) {
        track.requireKeyframe()
        if (track !== activeTrack) return
        postDecoderWork {
            Log.w(TAG, "Resetting video after discontinuity: $reason")
            maybeCancelScheduledDraining()
            cancelPendingVideoStallCheck()
            decoder?.flush()
            parkedInputBuffers.clear()
            queuedFramesByPts.clear()
            scheduledFramesByPts.clear()
            stallHorizon.reset()
            maxFedPtsUs = 0L
            noDisplayBeforePts = Long.MIN_VALUE
            isPlaybackStartEventArmed = true
            if (clock?.isVideoDriven == true) {
                timelineStarted = false
                lastKnownClockTimeUs = 0L
                clock.reset()
            }
            if (stallHorizon.beginStallNow()) beginVideoStall()
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
     * Install a pending track. The [SwapPhase] state machine in [tryFeedDecoder] will
     * decide between cut-in and flush-and-swap, then call [performSwap].
     * [onActivated] is called on the HandlerThread at the moment of the swap.
     */
    fun setPendingTrack(track: VideoRendererTrack, onActivated: (() -> Unit)?) {
        hasPendingTrack = true
        handler.post {
            pendingTrack?.setOnDataAvailable(null)
            noDisplayBeforePts = 0L
            track.setBufferState(JitterBuffer.State.PENDING)
            pendingTrack = track
            trackSwapPhase = TrackSwapPhase.AwaitingKeyframe
            onTrackActivated = onActivated
            track.setOnDataAvailable {
                postDecoderWork {
                    cancelPendingVideoStallCheck()
                    tryFeedDecoder()
                    requestVideoStallCheck()
                }
            }

            awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
            val timeout = Runnable {
                awaitingKeyframeTimeout = null
                if (trackSwapPhase is TrackSwapPhase.AwaitingKeyframe) {
                    Log.w(
                        TAG,
                        "AwaitingKeyframe timed out after ${AWAITING_KEYFRAME_TIMEOUT_MS}ms, forcing FlushAndSwap"
                    )
                    trackSwapPhase = TrackSwapPhase.FlushAndSwap
                    runDecoderWorkSafely { tryFeedDecoder() }
                }
            }
            awaitingKeyframeTimeout = timeout
            handler.postDelayed(timeout, AWAITING_KEYFRAME_TIMEOUT_MS)
        }
    }

    // MARK: - Drain loop + swap state machine (HandlerThread only)

    private fun tryFeedDecoder() {
        maybeCancelScheduledDraining()
        if (!prepareClockForDrain()) {
            return
        }
        maybePromotePendingTrack()
        maybeApplyPendingCodecData()

        // --- Drain active track ---
        while (parkedInputBuffers.isNotEmpty()) {
            val mediaTimeUs = playbackTimeUsForScheduling()

            val nextPts = activeTrack.peekNextTimestampUs() ?: run {
                requestVideoStallCheck()
                return
            }

            if (mediaTimeUs != null) {
                val aheadUs = nextPts - mediaTimeUs
                if (aheadUs > MAX_AHEAD_US) {
                    val delayMs = ((aheadUs - MAX_AHEAD_US) / 1000L).coerceIn(1L, 100L)
                    delayedDrainToken = Any()
                    handler.postDelayed(
                        { runDecoderWorkSafely { tryFeedDecoder() } },
                        delayedDrainToken,
                        delayMs,
                    )
                    return
                }
            }

            val frontFrameIntervalUs = activeTrack.frontFrameIntervalUs
            val (entry, playable) = activeTrack.dequeue()
            if (entry == null) {
                requestVideoStallCheck()
                return
            }

            val index = parkedInputBuffers.removeFirst()
            val queuedAtNs = System.nanoTime()
            if (decoder?.fillInputBuffer(index, entry.item.payload, entry.item.timestampUs) == true) {
                maxFedPtsUs = advanceRenditionSwitchProgressUs(
                    currentProgressUs = maxFedPtsUs,
                    submittedPtsUs = entry.item.timestampUs,
                )
                stallHorizon.recordCodecInputSubmitted(queuedAtNs)
                queuedFramesByPts.add(
                    entry.item.timestampUs,
                    QueuedFrameMetadata(
                        trackName = activeTrack.trackName,
                        queuedAtNs = queuedAtNs,
                        playable = playable,
                        frontFrameIntervalUs = frontFrameIntervalUs,
                    ),
                )
                metrics?.recordVideoDecodeBufferSubmitted(activeTrack.trackName)
            } else if (playable) {
                requestVideoStallCheck()
            }

            if (!playable) metrics?.recordVideoFrameDropped()
        }
    }

    private fun maybeCancelScheduledDraining() {
        delayedDrainToken?.let { handler.removeCallbacksAndMessages(it) }
        delayedDrainToken = null
    }

    private fun cancelPendingVideoStallCheck() {
        pendingStallCheck?.let { handler.removeCallbacks(it) }
        pendingStallCheck = null
        stallHorizon.clearPendingStallMarker()
    }

    private fun requestVideoStallCheck() {
        cancelPendingVideoStallCheck()

        maybePromotePendingTrack()
        if (activeTrack.peekNextTimestampUs() != null && parkedInputBuffers.isNotEmpty()) {
            handler.post { runDecoderWorkSafely { tryFeedDecoder() } }
        }

        when (val decision = stallHorizon.evaluateStallStart(System.nanoTime())) {
            is VideoStallDecision.Wait -> scheduleVideoStallCheck(decision.delayNs)
            VideoStallDecision.BeginStall -> {
                beginVideoStall()
                requestVideoStallCheck()
            }
            VideoStallDecision.RecoverDecoder -> {
                recoverDecoder("No decoded output within the codec progress deadline")
            }
            VideoStallDecision.AlreadyStalled -> Unit
        }
    }

    private fun scheduleVideoStallCheck(afterNs: Long) {
        val delayMs = TimeUnit.NANOSECONDS.toMillis(afterNs).coerceAtLeast(1L)
        val check = Runnable {
            pendingStallCheck = null
            runDecoderWorkSafely { requestVideoStallCheck() }
        }
        pendingStallCheck = check
        handler.postDelayed(check, delayMs)
    }

    private fun beginVideoStall() {
        lastKnownClockTimeUs = currentPlaybackTimeUs()
        if (clock?.isVideoDriven == true && timelineStarted) {
            clock.setRate(0.0)
        }
        metrics?.noteStall(MediaFrameKind.VIDEO, stalled = true)
    }

    private fun endVideoStall() {
        if (clock?.isVideoDriven == true && timelineStarted) {
            clock.setRate(1.0)
        }
        metrics?.noteStall(MediaFrameKind.VIDEO, stalled = false)
    }

    private fun maybePromotePendingTrack() {
        val pending = pendingTrack
        val phase = trackSwapPhase
        if (pending != null && phase != null) {
            when (phase) {
                is TrackSwapPhase.AwaitingKeyframe -> {
                    // Discard stale non-keyframes that can never serve as a cut-in point.
                    while (true) {
                        val front = pending.peekFront() ?: break
                        if (front.second) break  // is keyframe
                        if (maxFedPtsUs - front.first <= CUT_IN_WINDOW_US) break
                        pending.discardFront()
                    }
                    // Decide strategy once a keyframe is available.
                    val kfPts = pending.firstKeyframePts
                    if (kfPts != null) {
                        awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
                        awaitingKeyframeTimeout = null
                        val gap = maxFedPtsUs - kfPts

                        trackSwapPhase = if (gap > FLUSH_THRESHOLD_US) {
                            Log.d(TAG, "Changing pending phase to flush-and-swap")

                            TrackSwapPhase.FlushAndSwap
                        } else {
                            Log.d(TAG, "Changing pending phase to cutting-in")
                            TrackSwapPhase.CuttingIn(kfPts)
                        }
                    }
                    // else: no keyframe yet — onDataAvailable will re-trigger when one arrives
                }

                is TrackSwapPhase.CuttingIn -> {
                    val kfPts = phase.keyframePts
                    pending.discardNonKeyframesBeforePts(kfPts)
                    if (maxFedPtsUs >= kfPts) {
                        noDisplayBeforePts = maxFedPtsUs
                        pending.setBufferState(JitterBuffer.State.PLAYING)
                        Log.d(TAG, "Performing swap via cutting-in phase")
                        performSwap(pending)
                        trackSwapPhase = null
                    }
                }

                is TrackSwapPhase.FlushAndSwap -> {
                    pending.setBufferState(JitterBuffer.State.PLAYING)
                    Log.d(TAG, "Performing swap via flush-and-swap")
                    performSwap(pending, hardFlush = true)
                    trackSwapPhase = null
                }
            }
        }

    }

    private fun maybeApplyPendingCodecData() {
        val csd = pendingCsd ?: return
        if (parkedInputBuffers.isEmpty()) return
        val dec = decoder ?: return
        val idx = parkedInputBuffers.removeFirst()
        dec.queueCodecConfig(idx, csd)
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

        ensureMatchingCodecs(activeTrack, newTrack)
        // Rendition switching assumes all video tracks use the same source timestamp domain.
        // If future tracks can use different domains, MediaTimestampAligner needs per-track
        // live edges or switch-time offsets before comparing keyframe and fed PTS values.

        val currentDecoder = decoder
        val reusesDecoder = currentDecoder != null
        if (currentDecoder != null) {
            if (hardFlush) {
                currentDecoder.flush()
                parkedInputBuffers.clear()
                queuedFramesByPts.clear()
                scheduledFramesByPts.clear()
                stallHorizon.reset()
                maxFedPtsUs = 0L
            }
            // else: decoder keeps running, parkedInputBuffers remain valid
        } else {
            // Decoder not yet initialized (swap before first keyframe on active track).
            val format = newTrack.getFormat()
            if (format != null) {
                val newDecoder = buildDecoder(format)
                decoder = newDecoder
                newDecoder.start()
                awaitingRecoveryKeyframe = false
            } else {
                Log.d(TAG, "performSwap: format not ready, deferring decoder init")
            }
        }

        activeTrack.setOnDataAvailable(null)
        activeTrack = newTrack
        isPlaybackStartEventArmed = true
        metrics?.resetVideoDecodeStats(newTrack.trackName)
        pendingCsd = if (reusesDecoder) extractCsd(newTrack) else null
        pendingTrack = null
        hasPendingTrack = false

        maybeCancelScheduledDraining()

        newTrack.setOnDataAvailable {
            postDecoderWork {
                cancelPendingVideoStallCheck()
                if (activeTrack.isProcessorReady) {
                    maybeInitDecoder()
                }
                tryFeedDecoder()
                requestVideoStallCheck()
            }
        }

        onTrackActivated?.invoke()
        onTrackActivated = null
    }

    private fun ensureMatchingCodecs(oldTrack: VideoRendererTrack, newTrack: VideoRendererTrack) {
        val activeMime = oldTrack.getFormat()?.getString(MediaFormat.KEY_MIME)
        val newMime = newTrack.getFormat()?.getString(MediaFormat.KEY_MIME)

        if (activeMime != null && newMime != null && activeMime != newMime) {
            error("Cannot switch codecs during adaptive swap: $activeMime → $newMime")
        }
    }

    private fun extractCsd(track: VideoRendererTrack): ByteArray? {
        // Extract CSD from the new track's format so the decoder can handle
        // adaptive resolution changes (needed for out-of-band CSD codecs like avc1/hev1).
        val newFormat = track.getFormat()
        if (newFormat != null) {
            val csd0 = newFormat.getByteBuffer("csd-0")
            if (csd0 != null) {
                csd0.rewind()
                val bytes0 = ByteArray(csd0.remaining()).also { csd0.get(it) }
                val csd1 = newFormat.getByteBuffer("csd-1")
                if (csd1 != null) {
                    csd1.rewind()
                    val bytes1 = ByteArray(csd1.remaining()).also { csd1.get(it) }
                    return bytes0 + bytes1
                } else {
                    return bytes0
                }
            }
        }
        return null
    }

    // Decoded frame handling (HandlerThread only)

    private fun onDecodedFrame(bufferIndex: Int, timestampUs: Long) {
        val outputAtNs = System.nanoTime()
        val metadata = queuedFramesByPts.remove(timestampUs)
        if (metadata == null) {
            decoder?.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            requestVideoStallCheck()
            return
        }
        metrics?.recordVideoDecodeTime(
            trackName = metadata.trackName,
            durationNs = outputAtNs - metadata.queuedAtNs,
            outputAtNs = outputAtNs,
        )
        val playable = metadata.playable
        stallHorizon.recordCodecInputResolved(submittedAtNs = metadata.queuedAtNs)
        val displayTimestampUs = timestampUs
        val dec = decoder ?: return

        // After a CuttingIn swap, suppress display of frames that overlap with the
        // previous rendition. They are still decoded (needed as reference frames) but
        // not rendered, preventing duplicate-frame stutter.
        if (timestampUs <= noDisplayBeforePts) {
            dec.releaseOutputBuffer(bufferIndex, false)
            if (timestampUs == noDisplayBeforePts) noDisplayBeforePts = Long.MIN_VALUE
            requestVideoStallCheck()
            return
        }

        if (!playable) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            requestVideoStallCheck()
            return
        }

        val mediaTimeUs = playbackTimeUsForScheduling()

        // If frame is too far behind the playback clock it means that we can't play it smoothly.
        val lateToleranceUs = activeTrack.targetBuffering.toMicrosecondsLongClamped()
        if (mediaTimeUs != null && displayTimestampUs < mediaTimeUs - lateToleranceUs) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            requestVideoStallCheck()
            return
        }

        val delayUs = if (mediaTimeUs != null) {
            displayTimestampUs - mediaTimeUs
        } else {
            timestampUs - activeTrack.estimatedPlaybackTimeUs()
        }

        val nowNs = outputAtNs
        val baseRenderNs = (nowNs + delayUs * 1000L)
        if (baseRenderNs > nowNs + MAX_RENDER_SCHEDULE_NS) {
            Log.w(TAG, "render timestamp is too far in the future")
        } else if (baseRenderNs < nowNs) {
            Log.w(TAG, "render timestamp is in the past by ${nowNs - baseRenderNs}Ns")
        }

        val renderNs = baseRenderNs.coerceIn(nowNs, nowNs + MAX_RENDER_SCHEDULE_NS)
        if (dec.releaseOutputBuffer(bufferIndex, renderNs)) {
            cancelPendingVideoStallCheck()
            val scheduledFrame = ScheduledFrameMetadata(
                trackName = activeTrack.trackName,
                trackEpoch = activeTrack.trackEpoch,
                targetBuffering = activeTrack.targetBuffering,
                sourceTimestampUs = timestampUs,
                presentationTimeUs = displayTimestampUs,
                clockTimeUs = mediaTimeUs ?: displayTimestampUs,
                buffer = activeTrack.depth,
                scheduledRenderTimeNs = renderNs,
                frontFrameIntervalUs = metadata.frontFrameIntervalUs,
            )
            if (usesReliableFrameRenderedCallbacks) {
                scheduledFramesByPts.add(displayTimestampUs, scheduledFrame)
                stallHorizon.recordSurfaceFrameSubmitted(
                    playable = true,
                    scheduledRenderTimeNs = renderNs,
                )
            } else {
                confirmRenderedFrame(scheduledFrame, renderNs)
            }
        }
        requestVideoStallCheck()
    }

    private fun onFrameRendered(timestampUs: Long, renderTimeNs: Long) {
        if (!usesReliableFrameRenderedCallbacks) return
        val metadata = scheduledFramesByPts.remove(timestampUs) ?: return
        confirmRenderedFrame(metadata, renderTimeNs)
        requestVideoStallCheck()
    }

    private fun confirmRenderedFrame(
        metadata: ScheduledFrameMetadata,
        renderTimeNs: Long,
    ) {
        stallHorizon.recordSurfaceFrameResolved(
            playable = true,
            scheduledRenderTimeNs = metadata.scheduledRenderTimeNs,
        )
        val shouldEndStall = stallHorizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = metadata.presentationTimeUs,
            renderTimeNs = renderTimeNs,
            frontFrameIntervalUs = metadata.frontFrameIntervalUs,
        )
        metrics?.recordVideoFrameDisplayed()
        emitPlaybackStartIfArmed(metadata)
        if (shouldEndStall) {
            endVideoStall()
        }
    }

    private fun emitPlaybackStartIfArmed(metadata: ScheduledFrameMetadata) {
        if (!isPlaybackStartEventArmed) return
        if (
            metadata.trackName != activeTrack.trackName ||
            metadata.trackEpoch != activeTrack.trackEpoch
        ) {
            return
        }
        isPlaybackStartEventArmed = false
        metrics?.videoPlaybackStarted(
            context = PlaybackStartContext(
                kind = MediaFrameKind.VIDEO,
                trackName = metadata.trackName,
                sourceTimestampUs = metadata.sourceTimestampUs,
                targetBuffering = metadata.targetBuffering,
                trackEpoch = metadata.trackEpoch,
            ),
            presentationTimeUs = metadata.presentationTimeUs,
            clockTimeUs = metadata.clockTimeUs,
            buffer = metadata.buffer,
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

    private fun recoverDecoder(reason: String, cause: Throwable? = null) {
        if (failed || awaitingRecoveryKeyframe) return

        val nowNs = System.nanoTime()
        if (!decoderRecoveryBudget.tryAcquire(nowNs)) {
            handleFatalError(
                IllegalStateException(
                    "Video decoder failed more than $MAX_DECODER_RECOVERIES_PER_WINDOW times " +
                        "within ${TimeUnit.NANOSECONDS.toSeconds(DECODER_RECOVERY_WINDOW_NS)}s: $reason",
                    cause,
                ),
            )
            return
        }

        awaitingRecoveryKeyframe = true
        Log.w(TAG, "Recovering video decoder: $reason", cause)

        val pendingRecoveryTrack = pendingTrack?.takeIf { it.firstKeyframePts != null }
        activeTrack.requireKeyframe()
        maybeCancelScheduledDraining()
        cancelPendingVideoStallCheck()
        awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
        awaitingKeyframeTimeout = null
        parkedInputBuffers.clear()
        queuedFramesByPts.clear()
        scheduledFramesByPts.clear()
        stallHorizon.reset()
        decoderGeneration++
        decoder?.release()
        decoder = null
        maxFedPtsUs = 0L
        noDisplayBeforePts = Long.MIN_VALUE
        pendingCsd = null
        isPlaybackStartEventArmed = true
        if (clock?.isVideoDriven == true) {
            timelineStarted = false
            lastKnownClockTimeUs = 0L
            clock.reset()
        }
        if (stallHorizon.beginStallNow()) beginVideoStall()

        if (pendingRecoveryTrack != null) {
            Log.d(TAG, "Promoting pending rendition during decoder recovery")
            pendingRecoveryTrack.setBufferState(JitterBuffer.State.PLAYING)
            performSwap(pendingRecoveryTrack)
            trackSwapPhase = null
            tryFeedDecoder()
        }
    }

    private fun handleFatalError(error: Throwable) {
        if (failed) {
            return
        }

        failed = true
        Log.e(TAG, "VideoRenderer fatal error", error)
        cancelPendingVideoStallCheck()
        stallHorizon.reset()
        parkedInputBuffers.clear()
        queuedFramesByPts.clear()
        scheduledFramesByPts.clear()
        decoderGeneration++
        decoder?.release()
        decoder = null
        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        onError(error)
    }

    private fun prepareClockForDrain(): Boolean {
        val mediaClock = clock ?: return true
        if (!mediaClock.isVideoDriven) return true
        if (timelineStarted) {
            return syncClockToTargetLatency()
        }
        return startVideoClockIfReady(mediaClock)
    }

    private fun startVideoClockIfReady(mediaClock: MediaClock): Boolean {
        if (activeTrack.state != JitterBuffer.State.PLAYING) return false
        val sourceStartUs = activeTrack.targetPlaybackPTS()
            ?: activeTrack.peekFront()?.first
            ?: return false
        val startUs = sourceStartUs
        timelineStarted = true
        lastKnownClockTimeUs = startUs
        mediaClock.setRate(1.0, startUs)
        Log.d(
            TAG,
            "Started video-driven clock sourceStartUs=$sourceStartUs displayStartUs=$startUs " +
                "bufferFillMs=${activeTrack.depthMs}",
        )
        return true
    }

    private fun syncClockToTargetLatency(): Boolean {
        val mediaClock = clock ?: return true
        if (!mediaClock.isVideoDriven) return true
        val desiredSourceUs = activeTrack.targetPlaybackPTS() ?: return true
        val desiredPlayheadUs = desiredSourceUs
        val currentPlayheadUs = currentPlaybackTimeUs()

        return when {
            desiredPlayheadUs > currentPlayheadUs + CLOCK_RETARGET_TOLERANCE_US -> {
                lastKnownClockTimeUs = desiredPlayheadUs
                mediaClock.setRate(1.0, desiredPlayheadUs)
                true
            }

            currentPlayheadUs > desiredPlayheadUs + CLOCK_RETARGET_TOLERANCE_US -> {
                lastKnownClockTimeUs = currentPlayheadUs
                mediaClock.setRate(0.0)
                scheduleDrainAfterUs(currentPlayheadUs - desiredPlayheadUs)
                false
            }

            else -> {
                mediaClock.setRate(1.0)
                true
            }
        }
    }

    private fun playbackTimeUsForScheduling(): Long? {
        val mediaClock = clock ?: return null
        if (mediaClock.isVideoDriven) {
            return if (timelineStarted) currentPlaybackTimeUs() else null
        }
        return mediaClock.currentTimeUs.takeIf { it > 0L }
    }

    private fun currentPlaybackTimeUs(): Long {
        val clockTimeUs = clock?.currentTimeUs ?: return lastKnownClockTimeUs
        if (clockTimeUs >= lastKnownClockTimeUs) {
            lastKnownClockTimeUs = clockTimeUs
            return clockTimeUs
        }
        return lastKnownClockTimeUs
    }

    private fun scheduleDrainAfterUs(delayUs: Long) {
        val delayMs = (delayUs / 1_000L).coerceIn(1L, 100L)
        delayedDrainToken = Any()
        handler.postDelayed({ runDecoderWorkSafely { tryFeedDecoder() } }, delayedDrainToken, delayMs)
    }

}
