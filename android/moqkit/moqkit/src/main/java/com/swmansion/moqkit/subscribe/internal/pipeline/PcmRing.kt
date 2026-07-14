package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlin.math.ceil
import kotlin.math.min

internal data class PcmWriteResult(
    val acceptedFrames: Int,
    val rejectedOldFrames: Int = 0,
    val evictedFrames: Int = 0,
    val silenceFrames: Int = 0,
)

/** Timestamp-positioned PCM16 ring with explicit admission effects. */
internal class PcmRing(
    val sampleRate: Int,
    val channels: Int,
    policy: AdmissionPolicy,
) {
    private var samples = ShortArray(capacityFrom(policy) * channels)
    private var writeFrame = 0L
    private var readFrame = 0L
    private var anchored = false
    private var buffering = true

    init {
        require(sampleRate > 0) { "invalid sample rate" }
        require(channels > 0) { "invalid channels" }
    }

    val capacity: Int
        get() = samples.size / channels

    val length: Int
        get() = (writeFrame - readFrame).coerceIn(0L, capacity.toLong()).toInt()

    val timestampUs: Long
        get() = multiplyOrMax(readFrame, MICROS_PER_SECOND) / sampleRate

    fun write(timestampUs: Long, samples: ShortArray, frameCount: Int): PcmWriteResult {
        require(timestampUs >= 0L) { "timestampUs must be non-negative" }
        require(frameCount >= 0) { "frameCount must be non-negative" }
        require(samples.size >= frameCount * channels) { "insufficient PCM samples" }
        if (frameCount == 0) return PcmWriteResult(acceptedFrames = 0)

        var start = timestampToFrame(timestampUs)
        var frames = frameCount
        var sourceOffset = 0
        var rejectedOld = 0
        var evicted = 0

        if (!anchored) {
            anchored = true
            readFrame = start
            writeFrame = start
        }

        val oldFrames = (readFrame - start).coerceAtLeast(0L).coerceAtMost(frames.toLong()).toInt()
        if (oldFrames > 0) {
            rejectedOld += oldFrames
            start += oldFrames
            sourceOffset += oldFrames
            frames -= oldFrames
        }
        if (frames == 0) {
            return PcmWriteResult(acceptedFrames = 0, rejectedOldFrames = rejectedOld)
        }

        if (frames > capacity) {
            val trim = frames - capacity
            start += trim
            sourceOffset += trim
            frames -= trim
            evicted += trim
        }

        val end = addOrMax(start, frames.toLong())
        val overflow = (end - readFrame - capacity).coerceAtLeast(0L).toInt()
        if (overflow > 0) {
            readFrame += overflow
            evicted += overflow
        }

        val silence = if (start > writeFrame) {
            min(start - writeFrame, capacity.toLong()).toInt().also {
                ringZero(writeFrame, it)
            }
        } else {
            0
        }

        ringCopy(start, samples, sourceOffset, frames)
        if (end > writeFrame) writeFrame = end
        if (writeFrame - readFrame >= capacity) buffering = false

        return PcmWriteResult(
            acceptedFrames = frames,
            rejectedOldFrames = rejectedOld,
            evictedFrames = evicted,
            silenceFrames = silence,
        )
    }

    fun read(output: ShortArray, maxFrames: Int): Int {
        require(maxFrames >= 0) { "maxFrames must be non-negative" }
        require(output.size >= maxFrames * channels) { "insufficient output samples" }
        if (buffering || maxFrames == 0) return 0
        val frames = min(writeFrame - readFrame, maxFrames.toLong()).toInt()
        if (frames <= 0) return 0
        ringRead(readFrame, output, frames)
        readFrame += frames
        return frames
    }

    fun resize(policy: AdmissionPolicy) {
        val newCapacity = capacityFrom(policy)
        if (newCapacity == capacity) return

        val framesToKeep = min(length, newCapacity)
        val recent = ShortArray(framesToKeep * channels)
        if (framesToKeep > 0) ringRead(writeFrame - framesToKeep, recent, framesToKeep)
        samples = ShortArray(newCapacity * channels)
        readFrame = writeFrame - framesToKeep
        if (framesToKeep > 0) ringCopy(readFrame, recent, 0, framesToKeep)
        buffering = true
    }

    fun reset() {
        samples.fill(0)
        writeFrame = 0L
        readFrame = 0L
        anchored = false
        buffering = true
    }

    private fun capacityFrom(policy: AdmissionPolicy): Int {
        require(sampleRate > 0) { "invalid sample rate" }
        require(channels > 0) { "invalid channels" }
        val durationFrames = ceil(sampleRate.toDouble() * policy.maxDurationUs / MICROS_PER_SECOND)
            .toLong()
            .coerceAtLeast(1L)
        val byteFrames = policy.maxBytes / (channels * PCM_BYTES_PER_SAMPLE)
        return minOf(policy.maxFrames.toLong(), durationFrames, byteFrames)
            .coerceIn(1L, Int.MAX_VALUE.toLong())
            .toInt()
    }

    private fun timestampToFrame(timestampUs: Long): Long =
        Math.round(timestampUs.toDouble() * sampleRate / MICROS_PER_SECOND)

    private fun ringCopy(position: Long, source: ShortArray, sourceOffset: Int, frames: Int) {
        val start = (position % capacity).toInt() * channels
        val count = frames * channels
        val first = min(count, samples.size - start)
        System.arraycopy(source, sourceOffset * channels, samples, start, first)
        if (first < count) {
            System.arraycopy(source, sourceOffset * channels + first, samples, 0, count - first)
        }
    }

    private fun ringRead(position: Long, output: ShortArray, frames: Int) {
        val start = (position % capacity).toInt() * channels
        val count = frames * channels
        val first = min(count, samples.size - start)
        System.arraycopy(samples, start, output, 0, first)
        if (first < count) System.arraycopy(samples, 0, output, first, count - first)
    }

    private fun ringZero(position: Long, frames: Int) {
        val start = (position % capacity).toInt() * channels
        val count = frames * channels
        val first = min(count, samples.size - start)
        samples.fill(0, start, start + first)
        if (first < count) samples.fill(0, 0, count - first)
    }

    private fun multiplyOrMax(left: Long, right: Long): Long = try {
        Math.multiplyExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun addOrMax(left: Long, right: Long): Long = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private companion object {
        const val PCM_BYTES_PER_SAMPLE = 2L
        const val MICROS_PER_SECOND = 1_000_000L
    }
}
