package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import uniffi.moq.MoqVideo

/**
 * Processed video frame ready for MediaCodec input.
 * Annex B encoded bytes with prepended CSD if needed.
 */
internal data class ProcessedFrame(
    val payload: ByteArray,
    val timestampUs: Long,
    val isKeyframe: Boolean,
)

/**
 * Owns a [JitterBuffer] and [VideoFrameProcessor] for one video rendition.
 *
 * Thread-safe: all mutable state is guarded by [lock].
 * [insert] is called from the ingest coroutine (IO thread).
 * [dequeue], [peekFront], and state-control methods are called from the
 * VideoRenderer's HandlerThread.
 *
 * [onDataAvailable] is fired **outside** the lock to avoid deadlocks.
 */
internal class VideoRendererTrack(
    val trackName: String,
    config: MoqVideo,
    targetBufferingUs: Long,
) {
    val processor = VideoFrameProcessor(config)

    private val buffer = JitterBuffer<ProcessedFrame>(targetBufferingUs)
    private val lock = Object()
    private var onDataAvailable: (() -> Unit)? = null

    @Volatile
    var lastIngestPtsUs: Long = 0L
        private set

    init {
        buffer.setOnDataAvailable {
            val cb = synchronized(lock) { onDataAvailable }
            cb?.invoke()
        }
    }

    fun insert(payload: ByteArray, timestampUs: Long, keyframe: Boolean) {
        lastIngestPtsUs = timestampUs
        val processed = processor.processPayload(payload, keyframe) ?: return
        val frame = ProcessedFrame(processed, timestampUs, keyframe)

        buffer.insert(frame, timestampUs)

        // When in PENDING state, the jitter buffer won't notify on insert.
        // Fire ourselves when a keyframe arrives so the swap state machine
        // can re-evaluate.
        if (buffer.state == JitterBuffer.State.PENDING && keyframe) {
            val cb = synchronized(lock) { onDataAvailable }
            cb?.invoke()
        }
    }

    fun peekFront(): Pair<Long, Boolean>? {
        val entry = buffer.peekFront() ?: return null
        return entry.timestampUs to entry.item.isKeyframe
    }

    /** Returns the PTS of the oldest entry only when in PLAYING state. */
    fun peekNextTimestampUs(): Long? = buffer.peekNextTimestampUs()

    fun dequeue(mediaTimeUs: Long? = null): Pair<JitterBuffer.Entry<ProcessedFrame>?, Boolean> =
        buffer.dequeue(mediaTimeUs)
    fun setBufferState(state: JitterBuffer.State) {
        buffer.setState(state)
    }

    val firstKeyframePts: Long?
        get() = buffer.peekWhere { it.item.isKeyframe }?.timestampUs

    fun discardNonKeyframesBeforePts(pts: Long) {
        while (true) {
            val front = buffer.peekFront() ?: break
            if (front.item.isKeyframe || front.timestampUs >= pts) break
            buffer.discardFront()
        }
    }

    fun discardFront(): Boolean = buffer.discardFront()

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
        buffer.setOnDataAvailable(if (callback != null) {
            { val cb = synchronized(lock) { onDataAvailable }; cb?.invoke() }
        } else null)
    }

    fun updateTargetBuffering(us: Long) {
        buffer.updateTargetBuffering(us)
    }

    fun flush() {
        buffer.flush()
    }

    val state: JitterBuffer.State get() = buffer.state
    val depthMs: Double get() = buffer.depthMs
    fun estimatedPlaybackTimeUs(): Long = buffer.estimatedPlaybackTimeUs()
    val isProcessorReady: Boolean get() = processor.isReady
    fun getFormat(): MediaFormat? = processor.getFormat()
}
