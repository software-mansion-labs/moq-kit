package com.swmansion.moqkit.subscribe.internal.playback

/**
 * Shared playback clock abstraction.
 *
 * Audio-backed playback updates the clock from the audio render thread. Video-only playback
 * owns a wall-clock-backed timeline so latency changes can retarget the video playhead without
 * depending on audio.
 */
internal interface MediaClock {
    val currentTimeUs: Long
    val isVideoDriven: Boolean

    fun setCurrentTimeUs(timestampUs: Long)
    fun setRate(rate: Double)
    fun setRate(rate: Double, timeUs: Long)
    fun reset()
}

/**
 * Clock driven externally by decoded audio playback.
 */
internal class AudioDrivenClock : MediaClock {
    @Volatile
    private var currentUs: Long = 0L

    override val currentTimeUs: Long
        get() = currentUs

    override val isVideoDriven: Boolean = false

    override fun setCurrentTimeUs(timestampUs: Long) {
        currentUs = timestampUs.coerceAtLeast(0L)
    }

    override fun setRate(rate: Double) = Unit

    override fun setRate(rate: Double, timeUs: Long) {
        setCurrentTimeUs(timeUs)
    }

    override fun reset() {
        currentUs = 0L
    }
}

/**
 * Wall-clock-backed playback clock used when video is the only selected media kind.
 */
internal class VideoDrivenClock(
    private val wallClockUs: () -> Long = { System.nanoTime() / 1_000L },
) : MediaClock {
    private val lock = Any()
    private var anchorTimeUs: Long = 0L
    private var anchorWallUs: Long = wallClockUs()
    private var rate: Double = 0.0

    override val currentTimeUs: Long
        get() = synchronized(lock) {
            currentTimeLocked(wallClockUs())
        }

    override val isVideoDriven: Boolean = true

    override fun setCurrentTimeUs(timestampUs: Long) {
        synchronized(lock) {
            anchorTimeUs = timestampUs.coerceAtLeast(0L)
            anchorWallUs = wallClockUs()
        }
    }

    override fun setRate(rate: Double) {
        val newRate = rate.coerceAtLeast(0.0)
        synchronized(lock) {
            if (newRate == this.rate) return
            val now = wallClockUs()
            anchorTimeUs = currentTimeLocked(now)
            anchorWallUs = now
            this.rate = newRate
        }
    }

    override fun setRate(rate: Double, timeUs: Long) {
        synchronized(lock) {
            anchorTimeUs = timeUs.coerceAtLeast(0L)
            anchorWallUs = wallClockUs()
            this.rate = rate.coerceAtLeast(0.0)
        }
    }

    override fun reset() {
        synchronized(lock) {
            anchorTimeUs = 0L
            anchorWallUs = wallClockUs()
            rate = 0.0
        }
    }

    private fun currentTimeLocked(nowUs: Long): Long {
        if (rate == 0.0) return anchorTimeUs
        val elapsedUs = nowUs - anchorWallUs
        if (elapsedUs <= 0L) return anchorTimeUs
        val advancedUs = (elapsedUs.toDouble() * rate).toLong()
        return try {
            Math.addExact(anchorTimeUs, advancedUs)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
    }
}
