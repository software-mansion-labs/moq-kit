package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlin.math.abs

/** Monotonic wall-clock driver used when video is the playback master. */
internal class WallClockDriver(
    private val timeSource: TimeSource,
) : AdjustableClockDriver {
    private val lock = Any()
    private var anchorMediaUs: Long? = null
    private var anchorNanos: Long = timeSource.nanoTime()
    private var rate: Double = 0.0

    override fun positionUs(): Long? = synchronized(lock) {
        positionLocked(timeSource.nanoTime())
    }

    override fun setRate(rate: Double) {
        require(rate.isFinite() && rate >= 0.0) { "clock rate must be finite and non-negative" }
        synchronized(lock) {
            if (rate == this.rate) return
            val now = timeSource.nanoTime()
            anchorMediaUs = positionLocked(now)
            anchorNanos = now
            this.rate = rate
        }
    }

    override fun setPositionAndRate(positionUs: Long, rate: Double) {
        require(positionUs >= 0L) { "clock position must be non-negative" }
        require(rate.isFinite() && rate >= 0.0) { "clock rate must be finite and non-negative" }
        synchronized(lock) {
            anchorMediaUs = positionUs
            anchorNanos = timeSource.nanoTime()
            this.rate = rate
        }
    }

    override fun reset() {
        synchronized(lock) {
            anchorMediaUs = null
            anchorNanos = timeSource.nanoTime()
            rate = 0.0
        }
    }

    private fun positionLocked(nowNanos: Long): Long? {
        val anchor = anchorMediaUs ?: return null
        if (rate == 0.0) return anchor
        val elapsedNanos = (nowNanos - anchorNanos).coerceAtLeast(0L)
        val advancedUs = (elapsedNanos.toDouble() * rate / NANOS_PER_MICROSECOND).toLong()
        return addClamped(anchor, advancedUs)
    }

    private fun addClamped(left: Long, right: Long): Long = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private companion object {
        const val NANOS_PER_MICROSECOND = 1_000.0
    }
}

/** Maps AudioTrack's unsigned playback-head frame counter onto media timestamps. */
internal class AudioDeviceClockDriver(
    private val sampleRate: Int,
    private val playbackHeadFrames: () -> Long?,
) : ClockDriver {
    private data class Segment(val deviceFrame: Long, val mediaStartUs: Long)

    private val lock = Any()
    private val segments = ArrayDeque<Segment>()
    private var writtenDeviceFrame: Long = 0L
    private var lastRawHead: Long? = null
    private var headWrapOffset: Long = 0L
    private var lastUnwrappedHead: Long? = null

    init {
        require(sampleRate > 0) { "sample rate must be positive" }
    }

    fun onFramesWritten(mediaStartUs: Long, frameCount: Int) {
        require(mediaStartUs >= 0L) { "media start must be non-negative" }
        require(frameCount >= 0) { "frame count must be non-negative" }
        if (frameCount == 0) return

        synchronized(lock) {
            val writeStart = writtenDeviceFrame
            val expectedStart = segments.lastOrNull()?.let { segment ->
                addClamped(segment.mediaStartUs, framesToUs(writeStart - segment.deviceFrame))
            }
            if (expectedStart == null || absDifference(expectedStart, mediaStartUs) > frameDurationUs()) {
                segments.addLast(Segment(writeStart, mediaStartUs))
            }
            writtenDeviceFrame = addClamped(writeStart, frameCount.toLong())
        }
    }

    override fun positionUs(): Long? = synchronized(lock) {
        val head = unwrappedHeadLocked() ?: return null
        while (segments.size > 1 && segments[1].deviceFrame <= head) {
            segments.removeFirst()
        }
        val segment = segments.firstOrNull() ?: return null
        if (head < segment.deviceFrame) return segment.mediaStartUs
        addClamped(segment.mediaStartUs, framesToUs(head - segment.deviceFrame))
    }

    private fun unwrappedHeadLocked(): Long? {
        val raw = playbackHeadFrames()?.and(UNSIGNED_INT_MASK) ?: return null
        val previousRaw = lastRawHead
        if (previousRaw != null && raw < previousRaw && previousRaw - raw > WRAP_DETECTION_THRESHOLD) {
            headWrapOffset = addClamped(headWrapOffset, UNSIGNED_INT_RANGE)
        }
        lastRawHead = raw
        val candidate = addClamped(headWrapOffset, raw)
        val monotonic = maxOf(lastUnwrappedHead ?: candidate, candidate)
        lastUnwrappedHead = monotonic
        return monotonic
    }

    private fun framesToUs(frames: Long): Long = try {
        Math.multiplyExact(frames.coerceAtLeast(0L), MICROS_PER_SECOND) / sampleRate
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun frameDurationUs(): Long = (MICROS_PER_SECOND / sampleRate).coerceAtLeast(1L)

    private fun absDifference(left: Long, right: Long): Long {
        val difference = try {
            Math.subtractExact(left, right)
        } catch (_: ArithmeticException) {
            return Long.MAX_VALUE
        }
        return when {
            difference == Long.MIN_VALUE -> Long.MAX_VALUE
            difference < 0L -> -difference
            else -> difference
        }
    }

    private fun addClamped(left: Long, right: Long): Long = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private companion object {
        const val MICROS_PER_SECOND = 1_000_000L
        const val UNSIGNED_INT_MASK = 0xffff_ffffL
        const val UNSIGNED_INT_RANGE = 0x1_0000_0000L
        const val WRAP_DETECTION_THRESHOLD = 0x8000_0000L
    }
}
