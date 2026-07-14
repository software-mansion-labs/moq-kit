package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.RetargetDecision

internal fun interface ClockDriver {
    fun positionUs(): Long?
}

internal interface AdjustableClockDriver : ClockDriver {
    fun setRate(rate: Double)
    fun setPositionAndRate(positionUs: Long, rate: Double)
    fun reset()
}

internal enum class DriverKind { AUDIO, VIDEO }

/** Pure master-clock selection, wall-clock control, and latency-retarget policy. */
internal class PlaybackClock(
    private val policy: ClockPolicy,
    timeSource: TimeSource,
) {
    private val lock = Any()
    private val drivers = mutableMapOf<DriverKind, ClockDriver>(
        DriverKind.VIDEO to WallClockDriver(timeSource),
    )
    private var liveEdgeUs: Long? = null

    fun attachDriver(driver: ClockDriver, kind: DriverKind) {
        synchronized(lock) { drivers[kind] = driver }
    }

    fun detachDriver(kind: DriverKind) {
        synchronized(lock) { drivers.remove(kind) }
    }

    val activeDriverKind: DriverKind?
        get() = synchronized(lock) { activeDriverKindLocked() }

    fun nowMediaUs(): Long? = synchronized(lock) {
        activeDriverKindLocked()?.let { drivers[it]?.positionUs() }
    }

    fun startVideoAt(positionUs: Long) {
        require(positionUs >= 0L) { "video position must be non-negative" }
        synchronized(lock) {
            adjustableVideoDriverLocked().setPositionAndRate(positionUs, NORMAL_RATE)
        }
    }

    fun pauseVideo() {
        synchronized(lock) { adjustableVideoDriverLocked().setRate(PAUSED_RATE) }
    }

    fun resumeVideo() {
        synchronized(lock) { adjustableVideoDriverLocked().setRate(NORMAL_RATE) }
    }

    fun resetVideo() {
        synchronized(lock) {
            adjustableVideoDriverLocked().reset()
            liveEdgeUs = null
        }
    }

    fun onLiveEdge(positionUs: Long) {
        require(positionUs >= 0L) { "live edge must be non-negative" }
        synchronized(lock) { liveEdgeUs = positionUs }
    }

    /** Selects and applies the video-clock adjustment. Audio-master playback is never retargeted. */
    fun retarget(targetLatencyUs: Long): RetargetDecision = synchronized(lock) {
        require(targetLatencyUs >= 0L) { "target latency must be non-negative" }
        if (activeDriverKindLocked() != DriverKind.VIDEO) return RetargetDecision.NoOp
        val driver = adjustableVideoDriverLocked()
        val current = driver.positionUs() ?: return RetargetDecision.NoOp
        val edge = liveEdgeUs ?: return RetargetDecision.NoOp
        val desired = (edge - targetLatencyUs).coerceAtLeast(0L)
        val delta = subtractClamped(desired, current)
        val magnitude = absoluteMagnitude(delta)

        if (magnitude <= policy.retargetToleranceUs) {
            driver.setRate(NORMAL_RATE)
            return RetargetDecision.NoOp
        }
        if (magnitude >= policy.jumpThresholdUs) {
            driver.setPositionAndRate(desired, NORMAL_RATE)
            return RetargetDecision.Jump(desired)
        }

        val availableRange = (policy.jumpThresholdUs - policy.retargetToleranceUs).coerceAtLeast(1L)
        val normalized = ((magnitude - policy.retargetToleranceUs).toDouble() / availableRange)
            .coerceIn(0.0, 1.0)
        val rate = if (delta > 0L) {
            NORMAL_RATE + normalized * (policy.maxRate - NORMAL_RATE)
        } else {
            NORMAL_RATE - normalized * (NORMAL_RATE - policy.minRate)
        }
        val boundedRate = rate.coerceIn(policy.minRate, policy.maxRate)
        driver.setRate(boundedRate)
        RetargetDecision.Nudge(boundedRate)
    }

    private fun activeDriverKindLocked(): DriverKind? = when {
        drivers.containsKey(DriverKind.AUDIO) -> DriverKind.AUDIO
        drivers.containsKey(DriverKind.VIDEO) -> DriverKind.VIDEO
        else -> null
    }

    private fun adjustableVideoDriverLocked(): AdjustableClockDriver =
        drivers[DriverKind.VIDEO] as? AdjustableClockDriver
            ?: error("video clock driver is not adjustable")

    private fun subtractClamped(left: Long, right: Long): Long = try {
        Math.subtractExact(left, right)
    } catch (_: ArithmeticException) {
        if (left >= right) Long.MAX_VALUE else Long.MIN_VALUE
    }

    private fun absoluteMagnitude(value: Long): Long = when {
        value == Long.MIN_VALUE -> Long.MAX_VALUE
        value < 0L -> -value
        else -> value
    }

    private companion object {
        const val PAUSED_RATE = 0.0
        const val NORMAL_RATE = 1.0
    }
}
