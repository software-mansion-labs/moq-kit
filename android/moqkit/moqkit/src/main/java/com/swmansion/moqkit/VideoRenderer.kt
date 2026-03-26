package com.swmansion.moqkit

import android.util.Log
import android.view.Surface
import uniffi.moq.MoqVideo

private const val TAG = "VideoRenderer"

/**
 * Processed video frame ready for MediaCodec input.
 * Annex B encoded bytes with prepended CSD if needed.
 */
internal data class ProcessedFrame(
    val payload: ByteArray,
    val timestampUs: Long,
)

/**
 * Orchestrates JitterBuffer + VideoDecoder for real-time video rendering.
 *
 * Frames are buffered in the jitter buffer as raw payloads (before decoding).
 * When MediaCodec signals input buffer availability, frames are pulled from
 * the jitter buffer and submitted for decoding. All frames (playable or not)
 * are decoded to maintain the decoder's reference picture chain; non-playable
 * frames are released with render=false.
 *
 * Uses MediaCodec's scheduled release (`releaseOutputBuffer(index, renderTimestampNs)`)
 * to let the system compositor handle vsync-aligned display timing.
 *
 * ## Thread model
 * - **IO thread**: [submitFrame] — inserts into the JitterBuffer (thread-safe), posts
 *   [tryFeedDecoder] to the decoder HandlerThread.
 * - **HandlerThread**: all decoder interaction — [tryFeedDecoder], [onDecodedFrame],
 *   [parkedInputBuffers], [playabilityMap]. No locks needed for these structures.
 * - **Main/caller thread**: lifecycle only — [start], [stop], [flush].
 *
 * ## Feed loop
 * [tryFeedDecoder] is the single entry-point for matching parked decoder input
 * buffers with jitter-buffer frames. It is triggered from three places:
 *   1. [onInputBufferAvailable] — decoder freed an input slot.
 *   2. [submitFrame] (posted) — a new frame arrived; parked buffer may be waiting.
 *   3. [JitterBuffer.setOnDataAvailable] — buffer transitioned empty→non-empty while PLAYING.
 */
internal class VideoRenderer(
    private val config: MoqVideo,
    private val surface: Surface,
    targetBufferingUs: Long,
    private val timebase: MediaTimebase? = null,
    private val metrics: PlaybackMetricsAccumulator? = null,
) {
    private val jitterBuffer = JitterBuffer<ProcessedFrame>(targetBufferingUs).also { jb ->
        if (metrics != null) {
            jb.onStartPlaying = { metrics.videoStallEnded() }
            jb.onStartBuffering = { metrics.videoStallBegan() }
        }
        // Fires outside JitterBuffer's lock, on the insert thread (IO).
        // Just schedule a drain on the HandlerThread — safe and non-blocking.
        jb.setOnDataAvailable {
            decoder?.handler?.post { tryFeedDecoder() }
        }
    }
    private val processor = VideoFrameProcessor(config)

    @Volatile
    private var decoder: VideoDecoder? = null

    // Pending input buffer indices waiting for jitter-buffer data.
    // Only accessed on the decoder HandlerThread — no lock needed.
    private val parkedInputBuffers = ArrayDeque<Int>()

    // Maps PTS → playable flag, set at dequeue time and consumed at output time.
    // Only accessed on the decoder HandlerThread — no lock needed.
    private val playabilityMap = HashMap<Long, Boolean>()

    companion object {
        /**
         * Don't submit a frame to the decoder whose PTS is more than this far ahead
         * of the current audio clock. This bounds how far in the future we schedule
         * surface release (MediaCodec breaks with scheduled release > ~200–300 ms out).
         */
        private const val MAX_AHEAD_US = 500_000L

        /**
         * Hard cap on scheduled surface release offset from now, in nanoseconds.
         * Safety net that catches any edge case where the feed gate was not enough.
         */
        private const val MAX_RENDER_SCHEDULE_NS = 500_000_000L

        /** Drop decoded frames that are this far behind the playback head. */
        private const val LATE_DROP_THRESHOLD_US = 50_000L
    }

    /** PTS of the most recently submitted frame, in microseconds. */
    @Volatile
    var lastIngestPtsUs: Long = 0L
        private set

    val bufferFillMs: Double get() = jitterBuffer.depthMs

    private var delayedDrainToken: Object? = null

    fun start() {
        Log.d(TAG, "Starting: codec=${config.codec}")

        if (processor.isReady) {
            initDecoder()
        } else {
            Log.d(TAG, "Deferring decoder init until CSD is available")
        }

        Log.d(TAG, "VideoRenderer started")
    }

    private fun initDecoder() {
        val format = processor.getFormat()
            ?: throw IllegalStateException("Cannot init decoder: format not ready")

        val videoDecoder = VideoDecoder(
            format,
            surface,
            onInputBufferAvailable = { index ->
                // Runs on HandlerThread.
                parkedInputBuffers.addLast(index)
                tryFeedDecoder()
            },
            onOutputBufferAvailable = { bufferIndex, timestampUs ->
                // Runs on HandlerThread.
                onDecodedFrame(bufferIndex, timestampUs)
            },
        )
        decoder = videoDecoder
        videoDecoder.start()
        Log.d(TAG, "Decoder initialized: $format")
    }

    /** Submit a compressed video frame for buffering and eventual decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long, keyframe: Boolean) {
        lastIngestPtsUs = timestampUs
        val processed = processor.processPayload(payload, keyframe) ?: return

        if (decoder == null && processor.isReady) {
            initDecoder()
        }

        jitterBuffer.insert(ProcessedFrame(processed, timestampUs), timestampUs)
    }

    /**
     * Match parked decoder input buffers with jitter-buffer frames.
     *
     * Must run on the decoder HandlerThread. Loops until the jitter buffer is
     * empty/buffering, we run out of parked input buffers, or the next frame is
     * too far ahead of the playback clock (schedules a retry via postDelayed).
     */

    private fun tryFeedDecoder() {
        if (delayedDrainToken != null) {
            decoder?.handler?.removeCallbacksAndMessages(delayedDrainToken)
            delayedDrainToken = null
        }

        while (parkedInputBuffers.isNotEmpty()) {
            val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

            val nextPts = jitterBuffer.peekNextTimestampUs() ?: return  // empty or still buffering

            if (mediaTimeUs != null) {
                val aheadUs = nextPts - mediaTimeUs
                if (aheadUs > MAX_AHEAD_US) {
                    val delayMs = ((aheadUs - MAX_AHEAD_US) / 1000L).coerceIn(1L, 100L)

                    delayedDrainToken = Object()
                    decoder?.handler?.postDelayed({
                        tryFeedDecoder()
                    }, delayedDrainToken, delayMs)
                    return
                }
            }

            val (entry, playable) = jitterBuffer.dequeue(mediaTimeUs)
            if (entry == null) return

            val index = parkedInputBuffers.removeFirst()
            playabilityMap[entry.item.timestampUs] = playable
            decoder?.fillInputBuffer(index, entry.item.payload, entry.item.timestampUs)
        }
    }

    /** Called on the decoder HandlerThread when a frame is decoded. */
    private fun onDecodedFrame(bufferIndex: Int, timestampUs: Long) {
        val playable = playabilityMap.remove(timestampUs) ?: true

        val dec = decoder ?: return

        if (!playable) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val mediaTimeUs = timebase?.currentTimeUs?.takeIf { it > 0L }

        if (mediaTimeUs != null && timestampUs < mediaTimeUs - LATE_DROP_THRESHOLD_US) {
            dec.releaseOutputBuffer(bufferIndex, false)
            metrics?.recordVideoFrameDropped()
            return
        }

        val delayUs = if (mediaTimeUs != null) {
            timestampUs - mediaTimeUs
        } else {
            timestampUs - jitterBuffer.estimatedPlaybackTimeUs()
        }

        val nowNs = System.nanoTime()
        val renderNs = (nowNs + delayUs * 1000L).coerceIn(nowNs, nowNs + MAX_RENDER_SCHEDULE_NS)
        dec.releaseOutputBuffer(bufferIndex, renderNs)
        metrics?.recordVideoFrameDisplayed()
    }

    fun updateTargetBuffering(ms: Int) {
        jitterBuffer.updateTargetBuffering(ms.toLong() * 1000)
    }

    fun stop() {
        Log.d(TAG, "Stopping VideoRenderer")
        jitterBuffer.flush()
        val dec = decoder
        decoder = null
        if (dec != null) {
            // Post teardown to HandlerThread so it runs after any in-progress callback,
            // then release() quits the thread cleanly via quitSafely().
            dec.handler.post {
                parkedInputBuffers.clear()
                playabilityMap.clear()
                dec.release()
            }
        }
        Log.d(TAG, "VideoRenderer stopped")
    }
}
