package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import com.swmansion.moqkit.subscribe.BufferDepth
import uniffi.moq.MoqVideo
import java.time.Duration
import java.util.concurrent.atomic.AtomicLong

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
    val trackEpoch: Long,
    config: MoqVideo,
    val targetBuffering: Duration,
) {
    val processor = VideoFrameProcessor(config)

    private val buffer = JitterBuffer<ProcessedFrame>(targetBuffering.toMicrosecondsLongClamped())
    private val lock = Object()
    private val bufferedBytes = AtomicLong(0L)
    private var onDataAvailable: (() -> Unit)? = null

    init {
        buffer.setOnDataAvailable {
            val cb = synchronized(lock) { onDataAvailable }
            cb?.invoke()
        }
    }

    fun insert(payload: ByteArray, timestampUs: Long, keyframe: Boolean): Boolean {
        val processed = processor.processPayload(payload, keyframe) ?: return false
        val frame = ProcessedFrame(processed, timestampUs, keyframe)

        bufferedBytes.addAndGet(processed.size.toLong())
        buffer.insert(frame, timestampUs)

        // When in PENDING state, the jitter buffer won't notify on insert.
        // Fire ourselves when a keyframe arrives so the swap state machine
        // can re-evaluate.
        if (buffer.state == JitterBuffer.State.PENDING && keyframe) {
            val cb = synchronized(lock) { onDataAvailable }
            cb?.invoke()
        }
        return true
    }

    fun peekFront(): Pair<Long, Boolean>? {
        val entry = buffer.peekFront() ?: return null
        return entry.timestampUs to entry.item.isKeyframe
    }

    /** Returns the PTS of the oldest entry only when in PLAYING state. */
    fun peekNextTimestampUs(): Long? = buffer.peekNextTimestampUs()

    fun dequeue(): Pair<JitterBuffer.Entry<ProcessedFrame>?, Boolean> =
        buffer.dequeue().also { (entry, _) ->
            entry?.let { bufferedBytes.addAndGet(-it.item.payload.size.toLong()) }
        }
    fun setBufferState(state: JitterBuffer.State) {
        buffer.setState(state)
    }

    val firstKeyframePts: Long?
        get() = buffer.peekWhere { it.item.isKeyframe }?.timestampUs

    fun discardNonKeyframesBeforePts(pts: Long) {
        while (true) {
            val front = buffer.peekFront() ?: break
            if (front.item.isKeyframe || front.timestampUs >= pts) break
            if (buffer.discardFront()) {
                bufferedBytes.addAndGet(-front.item.payload.size.toLong())
            }
        }
    }

    fun discardFront(): Boolean {
        val front = buffer.peekFront() ?: return false
        val discarded = buffer.discardFront()
        if (discarded) bufferedBytes.addAndGet(-front.item.payload.size.toLong())
        return discarded
    }

    fun setOnDataAvailable(callback: (() -> Unit)?) {
        synchronized(lock) { onDataAvailable = callback }
        buffer.setOnDataAvailable(if (callback != null) {
            { val cb = synchronized(lock) { onDataAvailable }; cb?.invoke() }
        } else null)
    }

    fun updateTargetBuffering(targetBuffering: Duration): Boolean =
        buffer.updateTargetBuffering(targetBuffering.toMicrosecondsLongClamped())

    fun flush() {
        buffer.flush()
        bufferedBytes.set(0L)
    }

    val state: JitterBuffer.State get() = buffer.state
    val depthMs: Double get() = buffer.depthMs
    val depth: Duration get() = durationFromMilliseconds(buffer.depthMs) ?: Duration.ZERO
    val bufferDepth: BufferDepth get() = BufferDepth(
        frames = buffer.count,
        bytes = bufferedBytes.get().coerceAtLeast(0L),
        durationUs = depth.toMicrosecondsLongClamped(),
    )
    fun estimatedPlaybackTimeUs(): Long = buffer.estimatedPlaybackTimeUs()
    fun targetPlaybackPTS(): Long? = buffer.targetPlaybackPTS()
    val frontFrameIntervalUs: Long? get() = buffer.frontFrameIntervalUs
    val isProcessorReady: Boolean get() = processor.isReady
    fun getFormat(): MediaFormat? = processor.getFormat()
}
