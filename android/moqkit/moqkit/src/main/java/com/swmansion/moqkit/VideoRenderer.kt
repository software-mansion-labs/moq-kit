package com.swmansion.moqkit

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface

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
 *   [parkedInputBuffers], [playabilityMap], swap state machine. No locks needed for these.
 * - **Any thread**: [setPendingTrack] — posts to HandlerThread.
 * - **Caller thread**: lifecycle only — [start], [stop].
 */
internal class VideoRenderer(
    @Volatile private var activeTrack: VideoRendererTrack,
    private val surface: Surface,
    private val timebase: MediaTimebase? = null,
    private val metrics: PlaybackMetricsAccumulator? = null,
) {
    // MARK: - Pending-track swap state machine

    private sealed class SwapPhase {
        object AwaitingKeyframe : SwapPhase()
        data class CuttingIn(val keyframePts: Long) : SwapPhase()
        object FlushAndSwap : SwapPhase()
    }

    private data class FramePlayability(val playable: Boolean, val enqueuedAt:  Long)

    private var pendingTrack: VideoRendererTrack? = null
    private var pendingPhase: SwapPhase? = null
    private var onTrackActivated: (() -> Unit)? = null

    /** If non-null, a rendition switch is in progress. */
    @Volatile
    var hasPendingTrack: Boolean = false
        private set

    // MARK: - HandlerThread (persistent across decoder swaps)

    private val handlerThread = HandlerThread("MoQ-VideoRenderer").apply { start() }
    private val handler = Handler(handlerThread.looper)

    // MARK: - Decoder state (only accessed on HandlerThread)

    private var decoder: VideoDecoder? = null
    private val parkedInputBuffers = ArrayDeque<Int>()
    private val playabilityMap = HashMap<Long, FramePlayability>()
    private var delayedDrainToken: Object? = null

    /** PTS of the most recently fed frame to MediaCodec (used by swap state machine). */
    private var lastFedPtsUs: Long = 0L

    companion object {
        private const val MAX_AHEAD_US = 500_000L
        private const val MAX_RENDER_SCHEDULE_NS = 500_000_000L
        private const val LATE_DROP_THRESHOLD_US = 50_000L
        private const val CUT_IN_WINDOW_US = 500_000L
        private const val FLUSH_THRESHOLD_US = 2_000_000L
    }

    val bufferFillMs: Double get() = activeTrack.depthMs

    /** PTS of the most recently ingested frame from the network. */
    val lastIngestPtsUs: Long get() = activeTrack.lastIngestPtsUs

    // MARK: - Lifecycle

    fun start() {
        Log.d(TAG, "Starting")
        activeTrack.setOnDataAvailable {
            handler.post {
                if (decoder == null && activeTrack.isProcessorReady) {
                    initDecoder()
                }
                tryFeedDecoder()
            }
        }
        if (activeTrack.isProcessorReady) {
            handler.post { initDecoder() }
        } else {
            Log.d(TAG, "Deferring decoder init until CSD is available")
        }
        Log.d(TAG, "VideoRenderer started")
    }

    private fun initDecoder() {
        val format = activeTrack.getFormat()
            ?: throw IllegalStateException("Cannot init decoder: format not ready")
        decoder = buildDecoder(format)
        decoder!!.start()
        Log.d(TAG, "Decoder initialized: $format")
    }

    private fun buildDecoder(format: android.media.MediaFormat): VideoDecoder =
        VideoDecoder(
            format = format,
            surface = surface,
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
            pendingTrack = null
            pendingPhase = null
            parkedInputBuffers.clear()
            playabilityMap.clear()
            decoder?.release()
            decoder = null
            handlerThread.quitSafely()
        }
        Log.d(TAG, "VideoRenderer stopped")
    }

    fun updateTargetBuffering(ms: Int) {
        activeTrack.updateTargetBuffering(ms.toLong() * 1000)
    }

    // MARK: - Pending track API

    /**
     * Install a pending track. The [SwapPhase] state machine in [tryFeedDecoder] will
     * decide between cut-in and flush-and-swap, then call [performSwap].
     * [onActivated] is called on the HandlerThread at the moment of the swap.
     */
    fun setPendingTrack(track: VideoRendererTrack, onActivated: (() -> Unit)?) {
        hasPendingTrack = true
        handler.post {
            pendingTrack?.setOnDataAvailable(null)
            track.setBufferState(JitterBuffer.State.PENDING)
            pendingTrack = track
            pendingPhase = SwapPhase.AwaitingKeyframe
            onTrackActivated = onActivated
            track.setOnDataAvailable { handler.post { tryFeedDecoder() } }
        }
    }

    // MARK: - Drain loop + swap state machine (HandlerThread only)

    private fun tryFeedDecoder() {
        delayedDrainToken?.let { handler.removeCallbacksAndMessages(it) }
        delayedDrainToken = null

        // --- Pending track swap state machine ---
        val pending = pendingTrack
        val phase = pendingPhase
        if (pending != null && phase != null) {
            when (phase) {
                is SwapPhase.AwaitingKeyframe -> {
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
                        val gap = lastFedPtsUs - kfPts
                        pendingPhase = if (gap > FLUSH_THRESHOLD_US) {
                            SwapPhase.FlushAndSwap
                        } else {
                            SwapPhase.CuttingIn(kfPts)
                        }
                    }
                    // else: no keyframe yet — onDataAvailable will re-trigger when one arrives
                }

                is SwapPhase.CuttingIn -> {
                    val kfPts = phase.keyframePts
                    pending.discardNonKeyframesBeforePts(kfPts)
                    if (lastFedPtsUs >= kfPts) {
                        pending.setBufferState(JitterBuffer.State.PLAYING)
                        performSwap(pending)
                        pendingPhase = null
                    }
                }

                is SwapPhase.FlushAndSwap -> {
                    pending.setBufferState(JitterBuffer.State.PLAYING)
                    performSwap(pending, hardFlush = true)
                    pendingPhase = null
                }
            }
        }

        // --- Drain active track ---
        while (parkedInputBuffers.isNotEmpty()) {
            val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

            val nextPts = activeTrack.peekNextTimestampUs() ?: run {
                // Empty or still buffering — check for emergency swap.
                handleEmptyActive()
                return
            }

            if (mediaTimeUs != null) {
                val aheadUs = nextPts - mediaTimeUs
                if (aheadUs > MAX_AHEAD_US) {
                    val delayMs = ((aheadUs - MAX_AHEAD_US) / 1000L).coerceIn(1L, 100L)
                    delayedDrainToken = Object()
                    handler.postDelayed({ tryFeedDecoder() }, delayedDrainToken, delayMs)
                    return
                }
            }

            val (entry, playable) = activeTrack.dequeue(mediaTimeUs)
            if (entry == null) {
                handleEmptyActive()
                return
            }

            val index = parkedInputBuffers.removeFirst()
            lastFedPtsUs = entry.item.timestampUs
            playabilityMap[entry.item.timestampUs] = FramePlayability(playable, System.nanoTime())
            decoder?.fillInputBuffer(index, entry.item.payload, entry.item.timestampUs)

            if (!playable) metrics?.recordVideoFrameDropped()
        }
    }

    private fun handleEmptyActive() {
        val pending = pendingTrack
        if (pending != null && pending.peekFront()?.second == true) {
            // Emergency swap: active drained completely but pending has a keyframe.
            pending.setBufferState(JitterBuffer.State.PLAYING)
            performSwap(pending)
            pendingPhase = null
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

        val activeMime = activeTrack.getFormat()?.getString(android.media.MediaFormat.KEY_MIME)
        val newMime = newTrack.getFormat()?.getString(android.media.MediaFormat.KEY_MIME)
        if (activeMime != null && newMime != null && activeMime != newMime) {
            error("Cannot switch codecs during adaptive swap: $activeMime → $newMime")
        }

        activeTrack.setOnDataAvailable(null)

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

        playabilityMap.clear()
        delayedDrainToken = null

        activeTrack = newTrack
        pendingTrack = null
        hasPendingTrack = false

        newTrack.setOnDataAvailable {
            handler.post {
                if (decoder == null && activeTrack.isProcessorReady) {
                    initDecoder()
                }
                tryFeedDecoder()
            }
        }

        onTrackActivated?.invoke()
        onTrackActivated = null
    }

    // MARK: - Decoded frame handling (HandlerThread only)

    private fun onDecodedFrame(bufferIndex: Int, timestampUs: Long) {
        val playability = playabilityMap.remove(timestampUs) ?: FramePlayability(true, System.nanoTime())
        val dec = decoder ?: return

        if (!playability.playable) {
          Log.d(TAG, "Dropping video frame, set as non-playable")
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val processingTime = (System.nanoTime() - playability.enqueuedAt) / 1_000_000

        val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

        if (mediaTimeUs != null && timestampUs < mediaTimeUs - LATE_DROP_THRESHOLD_US) {
          Log.d(TAG, "Dropping frame due to being late, pts diff = ${(mediaTimeUs - timestampUs) / 1_000}ms, processing time = ${processingTime}ms")

            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val delayUs = if (mediaTimeUs != null) {
            timestampUs - mediaTimeUs
        } else {
            timestampUs - activeTrack.estimatedPlaybackTimeUs()
        }

        Log.d(TAG, "Frame processed in ${processingTime}ms")

        val nowNs = System.nanoTime()
        val renderNs = (nowNs + delayUs * 1000L).coerceIn(nowNs, nowNs + MAX_RENDER_SCHEDULE_NS)
        dec.releaseOutputBuffer(bufferIndex, renderNs)
        metrics?.recordVideoFrameDisplayed()
    }
}
