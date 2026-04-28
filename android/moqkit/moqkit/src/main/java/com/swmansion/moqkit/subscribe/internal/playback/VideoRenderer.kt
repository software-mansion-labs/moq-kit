package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "VideoRenderer"

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
    private val timebase: MediaTimebase? = null,
    private val metrics: PlaybackMetricsAccumulator? = null,
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
    private val parkedInputBuffers = ArrayDeque<Int>()
    private val queuedFramesByPts = HashMap<Long, QueuedFrameMetadata>()
    private var delayedDrainToken: Any? = null

    /** PTS of the most recently fed frame to MediaCodec (used by swap state machine). */
    private var lastFedPtsUs: Long = 0L

    /** After a CuttingIn swap, frames with PTS <= this value are decoded but not displayed
     *  to avoid showing duplicate frames from the overlap between old and new rendition. */
    private var noDisplayBeforePts: Long = Long.MIN_VALUE
    private var awaitingKeyframeTimeout: Runnable? = null

    /** CSD bytes to queue as BUFFER_FLAG_CODEC_CONFIG before feeding the new rendition's
     *  first frame, so the decoder can handle adaptive resolution changes. */
    private var pendingCsd: ByteArray? = null

    companion object {
        private const val MAX_AHEAD_US = 500_000L
        private const val MAX_RENDER_SCHEDULE_NS = 500_000_000L
        private const val LATE_DROP_THRESHOLD_US = 50_000L
        private const val CUT_IN_WINDOW_US = 500_000L
        private const val FLUSH_THRESHOLD_US = 2_000_000L
        private const val AWAITING_KEYFRAME_TIMEOUT_MS = 5_000L
        private const val HANDLER_SYNC_TIMEOUT_MS = 2_000L
    }

    val bufferFillMs: Double get() = activeTrack.depthMs

    /** PTS of the most recently ingested frame from the network. */
    val lastIngestPtsUs: Long get() = activeTrack.lastIngestPtsUs

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

        Log.d(TAG, "Decoder initialized: $format")
    }

    private fun buildDecoder(format: android.media.MediaFormat): VideoDecoder =
        VideoDecoder(
            format = format,
            surface = outputSurface,
            handler = handler,
            onInputBufferAvailable = { index ->
                parkedInputBuffers.addLast(index)
                tryFeedDecoder()
            },
            onOutputBufferAvailable = { bufferIndex, timestampUs ->
                onDecodedFrame(bufferIndex, timestampUs)
            },
        )

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")

        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        activeTrack.flush()
        handler.post {
            delayedDrainToken?.let { handler.removeCallbacksAndMessages(it) }
            delayedDrainToken = null
            awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
            awaitingKeyframeTimeout = null
            noDisplayBeforePts = 0L
            pendingCsd = null
            pendingTrack = null
            trackSwapPhase = null
            parkedInputBuffers.clear()
            queuedFramesByPts.clear()
            decoder?.release()
            decoder = null
            handlerThread.quitSafely()

            Log.d(TAG, "VideoRenderer stopped")
        }
    }

    fun updateTargetBuffering(ms: Int) {
        activeTrack.updateTargetBuffering(ms.toLong() * 1000)
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
            track.setOnDataAvailable { handler.post { tryFeedDecoder() } }

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
        maybePromotePendingTrack()
        maybeApplyPendingCodecData()

        // --- Drain active track ---
        while (parkedInputBuffers.isNotEmpty()) {
            val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

            val nextPts = activeTrack.peekNextTimestampUs() ?: run {
                return
            }

            if (mediaTimeUs != null) {
                val aheadUs = nextPts - mediaTimeUs
                if (aheadUs > MAX_AHEAD_US) {
                    val delayMs = ((aheadUs - MAX_AHEAD_US) / 1000L).coerceIn(1L, 100L)
                    delayedDrainToken = Any()
                    handler.postDelayed({ tryFeedDecoder() }, delayedDrainToken, delayMs)
                    return
                }
            }

            val (entry, playable) = activeTrack.dequeue(mediaTimeUs)
            if (entry == null) {
                return
            }

            val index = parkedInputBuffers.removeFirst()
            lastFedPtsUs = entry.item.timestampUs
            queuedFramesByPts[entry.item.timestampUs] = QueuedFrameMetadata(
                trackName = activeTrack.trackName,
                queuedAtNs = System.nanoTime(),
                playable = playable,
            )
            decoder?.fillInputBuffer(index, entry.item.payload, entry.item.timestampUs)

            if (!playable) metrics?.recordVideoFrameDropped()
        }
    }

    private fun maybeCancelScheduledDraining() {
        delayedDrainToken?.let { handler.removeCallbacksAndMessages(it) }
        delayedDrainToken = null
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
                        if (lastFedPtsUs - front.first <= CUT_IN_WINDOW_US) break
                        pending.discardFront()
                    }
                    // Decide strategy once a keyframe is available.
                    val kfPts = pending.firstKeyframePts
                    if (kfPts != null) {
                        awaitingKeyframeTimeout?.let { handler.removeCallbacks(it) }
                        awaitingKeyframeTimeout = null
                        val gap = lastFedPtsUs - kfPts

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
                    if (lastFedPtsUs >= kfPts) {
                        noDisplayBeforePts = lastFedPtsUs
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
        val csd = pendingCsd
        if (csd != null && parkedInputBuffers.isNotEmpty()) {
            decoder?.let { dec ->
                val idx = parkedInputBuffers.removeFirst()
                dec.queueCodecConfig(idx, csd)
                Log.d(TAG, "Queued CSD config buffer (${csd.size}B) for adaptive switch")
            }
            pendingCsd = null
        }
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

        val currentDecoder = decoder
        if (currentDecoder != null) {
            if (hardFlush) {
                currentDecoder.flush()
                parkedInputBuffers.clear()
            }
            // else: decoder keeps running, parkedInputBuffers remain valid
        } else {
            // Decoder not yet initialized (swap before first keyframe on active track).
            val format = newTrack.getFormat()
            if (format != null) {
                val newDecoder = buildDecoder(format)
                decoder = newDecoder
                newDecoder.start()
            } else {
                Log.d(TAG, "performSwap: format not ready, deferring decoder init")
            }
        }

        queuedFramesByPts.clear()

        activeTrack.setOnDataAvailable(null)
        activeTrack = newTrack
        metrics?.resetVideoDecodeStats(newTrack.trackName)
        pendingCsd = extractCsd(newTrack)
        pendingTrack = null
        hasPendingTrack = false

        maybeCancelScheduledDraining()

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
        if (metadata != null) {
            metrics?.recordVideoDecodeTime(
                trackName = metadata.trackName,
                durationNs = outputAtNs - metadata.queuedAtNs,
            )
        }
        val playable = metadata?.playable ?: true
        val dec = decoder ?: return

        // After a CuttingIn swap, suppress display of frames that overlap with the
        // previous rendition. They are still decoded (needed as reference frames) but
        // not rendered, preventing duplicate-frame stutter.
        if (timestampUs <= noDisplayBeforePts) {
            dec.releaseOutputBuffer(bufferIndex, false)
            if (timestampUs == noDisplayBeforePts) noDisplayBeforePts = Long.MIN_VALUE
            return
        }

        if (!playable) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

        // If frame is too far behind the timebase it means that we can't play it smoothly.
        if (mediaTimeUs != null && timestampUs < mediaTimeUs - LATE_DROP_THRESHOLD_US) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val delayUs = if (mediaTimeUs != null) {
            timestampUs - mediaTimeUs
        } else {
            timestampUs - activeTrack.estimatedPlaybackTimeUs()
        }

        val nowNs = outputAtNs
        val baseRenderNs = (nowNs + delayUs * 1000L)
        if (baseRenderNs > nowNs + MAX_RENDER_SCHEDULE_NS) {
            Log.w(TAG, "render timestamp is too far in the future")
        } else if (baseRenderNs < nowNs) {
            Log.w(TAG, "render timestamp is in the past")
        }

        val renderNs = baseRenderNs.coerceIn(nowNs, nowNs + MAX_RENDER_SCHEDULE_NS)
        dec.releaseOutputBuffer(bufferIndex, renderNs)
        metrics?.recordVideoFrameDisplayed()
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
        activeTrack.setOnDataAvailable(null)
        pendingTrack?.setOnDataAvailable(null)
        hasPendingTrack = false
        onError(error)
    }
}
