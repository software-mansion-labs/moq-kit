package com.swmansion.moqkit.subscribe.internal.playback

import java.time.Duration
import kotlin.math.ceil
import kotlin.math.min

/**
 * Circular buffer for interleaved 16-bit PCM samples (ShortArray).
 * Port of the iOS AudioRingBuffer with the same timestamp-based write positioning,
 * stall management, gap filling, and overflow handling.
 *
 * A "frame" = one sample per channel (i.e. `channels` shorts in the interleaved buffer).
 */
internal class AudioRingBuffer(
    val rate: Int,
    val channels: Int,
    latency: Duration,
) {
    private var buffer: ShortArray
    private var writeFrame: Long = 0L
    private var readFrame: Long = 0L

    var stalled: Boolean = true
        private set

    init {
        require(channels > 0) { "invalid channels" }
        require(rate > 0) { "invalid sample rate" }

        buffer = ShortArray(capacityForLatency(latency) * channels)
    }

    /** Total capacity in frames. */
    val capacity: Int get() = buffer.size / channels

    /** Number of frames available to read. */
    val length: Int get() = (writeFrame - readFrame).toInt()

    /** Timestamp of the current read position in microseconds. */
    val timestampUs: Long get() = (readFrame * 1_000_000L) / rate

    // -- Bulk copy helpers (operate on interleaved samples = frames * channels shorts) --

    /** Copy [frameCount] frames from [src] (offset [srcOffset] in frames) into ring at logical [pos] (in frames). */
    private fun ringCopy(pos: Long, src: ShortArray, srcOffset: Int, frameCount: Int) {
        val cap = capacity
        val start = (pos % cap).toInt() * channels
        val count = frameCount * channels
        val firstChunk = min(count, buffer.size - start)

        System.arraycopy(src, srcOffset * channels, buffer, start, firstChunk)
        if (firstChunk < count) {
            System.arraycopy(src, srcOffset * channels + firstChunk, buffer, 0, count - firstChunk)
        }
    }

    /** Copy [frameCount] frames from ring at logical [pos] into [dst] (at offset 0). */
    private fun ringRead(pos: Long, dst: ShortArray, frameCount: Int) {
        val cap = capacity
        val start = (pos % cap).toInt() * channels
        val count = frameCount * channels
        val firstChunk = min(count, buffer.size - start)

        System.arraycopy(buffer, start, dst, 0, firstChunk)
        if (firstChunk < count) {
            System.arraycopy(buffer, 0, dst, firstChunk, count - firstChunk)
        }
    }

    /** Zero-fill [frameCount] frames in ring starting at logical [pos]. */
    private fun ringZero(pos: Long, frameCount: Int) {
        val cap = capacity
        val start = (pos % cap).toInt() * channels
        val count = frameCount * channels
        val firstChunk = min(count, buffer.size - start)

        buffer.fill(0, start, start + firstChunk)
        if (firstChunk < count) {
            buffer.fill(0, 0, count - firstChunk)
        }
    }

    // -- Write / Read / Resize / Reset --

    /**
     * Write frames at the position determined by the timestamp.
     * [data] is interleaved PCM16 with [frameCount] frames (data.size == frameCount * channels).
     * Returns the number of frames discarded (too-old + overflow).
     */
    fun write(timestampUs: Long, data: ShortArray, frameCount: Int): Int {
        var start = Math.round((timestampUs.toDouble() / 1_000_000.0) * rate)
        var frames = frameCount
        var discarded = 0

        // First write after init/reset: anchor indices to the incoming timestamp
        if (stalled && writeFrame == 0L && readFrame == 0L) {
            readFrame = start
            writeFrame = start
        }

        // Ignore frames that are too old (before the read position)
        val offset = readFrame - start
        if (offset > frames) {
            return frames
        } else if (offset > 0) {
            discarded += offset.toInt()
            frames -= offset.toInt()
            start += offset
        }

        val end = start + frames

        // Check if we need to discard old frames to prevent overflow
        val overflow = end - readFrame - capacity
        if (overflow >= 0) {
            stalled = false
            discarded += overflow.toInt()
            readFrame += overflow
        }

        // Fill gaps with zeros if there's a discontinuity
        if (start > writeFrame) {
            val gapSize = min(start - writeFrame, capacity.toLong()).toInt()
            ringZero(writeFrame, gapSize)
        }

        // Write the actual samples
        val srcOffset = frameCount - frames
        ringCopy(start, data, srcOffset, frames)

        if (end > writeFrame) {
            writeFrame = end
        }

        return discarded
    }

    /**
     * Read up to [maxFrames] frames into [output] (interleaved).
     * Returns 0 while stalled.
     */
    fun read(output: ShortArray, maxFrames: Int): Int {
        if (stalled) return 0

        val frames = min(writeFrame - readFrame, maxFrames.toLong()).toInt()
        if (frames <= 0) return 0

        ringRead(readFrame, output, frames)
        readFrame += frames
        return frames
    }

    /** Resize the buffer to match a new latency target. Preserves recent samples. Triggers stall. */
    fun resize(latency: Duration) {
        val newCapacity = capacityForLatency(latency)
        if (newCapacity == capacity) return

        val newBuffer = ShortArray(newCapacity * channels)
        val framesToKeep = min(length, newCapacity)
        if (framesToKeep > 0) {
            val copyStart = writeFrame - framesToKeep
            // Read from old ring into temporary then copy to new buffer
            val temp = ShortArray(framesToKeep * channels)
            ringRead(copyStart, temp, framesToKeep)
            System.arraycopy(temp, 0, newBuffer, 0, framesToKeep * channels)
        }

        buffer = newBuffer
        readFrame = writeFrame - framesToKeep
        stalled = true
    }

    private fun capacityForLatency(latency: Duration): Int {
        require(!latency.isNegative && !latency.isZero) { "invalid latency" }

        val seconds = latency.seconds.toDouble() + latency.nano.toDouble() / 1_000_000_000.0
        val frames = ceil(rate.toDouble() * seconds).toInt()
        require(frames > 0) { "empty buffer" }
        return frames
    }

    /** Reset all state, clearing the buffer and re-entering stalled mode. */
    fun reset() {
        writeFrame = 0L
        readFrame = 0L
        stalled = true
        buffer.fill(0)
    }
}
