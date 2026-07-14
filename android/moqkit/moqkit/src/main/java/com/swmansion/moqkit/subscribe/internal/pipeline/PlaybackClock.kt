package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.RetargetDecision

internal fun interface ClockDriver {
    fun positionUs(): Long?
}

internal enum class DriverKind { AUDIO, VIDEO }

/** Pure master-clock selection and latency-retarget decision logic. */
internal class PlaybackClock(
    private val policy: ClockPolicy,
    @Suppress("unused") private val timeSource: TimeSource,
) {
    private val drivers = mutableMapOf<DriverKind, ClockDriver>()
    private var liveEdgeUs: Long? = null

    fun attachDriver(driver: ClockDriver, kind: DriverKind) {
        drivers[kind] = driver
    }

    fun detachDriver(kind: DriverKind) {
        drivers.remove(kind)
    }

    fun nowMediaUs(): Long? =
        drivers[DriverKind.AUDIO]?.positionUs()
            ?: drivers[DriverKind.VIDEO]?.positionUs()

    fun onLiveEdge(positionUs: Long) {
        require(positionUs >= 0L) { "live edge must be non-negative" }
        liveEdgeUs = positionUs
    }

    fun retarget(targetLatencyUs: Long): RetargetDecision {
        require(targetLatencyUs >= 0L) { "target latency must be non-negative" }
        val current = nowMediaUs() ?: return RetargetDecision.NoOp
        val edge = liveEdgeUs ?: return RetargetDecision.NoOp
        val desired = (edge - targetLatencyUs).coerceAtLeast(0L)
        val delta = desired - current
        val magnitude = absoluteMagnitude(delta)

        if (magnitude <= policy.retargetToleranceUs) return RetargetDecision.NoOp
        if (magnitude >= policy.jumpThresholdUs) return RetargetDecision.Jump(desired)

        val availableRange = (policy.jumpThresholdUs - policy.retargetToleranceUs).coerceAtLeast(1L)
        val normalized = ((magnitude - policy.retargetToleranceUs).toDouble() / availableRange)
            .coerceIn(0.0, 1.0)
        val rate = if (delta > 0L) {
            1.0 + normalized * (policy.maxRate - 1.0)
        } else {
            1.0 - normalized * (1.0 - policy.minRate)
        }
        return RetargetDecision.Nudge(rate.coerceIn(policy.minRate, policy.maxRate))
    }

    private fun absoluteMagnitude(value: Long): Long = when {
        value == Long.MIN_VALUE -> Long.MAX_VALUE
        value < 0L -> -value
        else -> value
    }
}
