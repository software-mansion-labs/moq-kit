package com.swmansion.moqkit.subscribe.internal.playback

/** Sliding-window limit for automatic decoder rebuilds. */
internal class DecoderRecoveryBudget(
    private val maxRecoveries: Int,
    private val windowNs: Long,
) {
    private val recoveryTimesNs = ArrayDeque<Long>()

    init {
        require(maxRecoveries > 0) { "maxRecoveries must be positive" }
        require(windowNs >= 0L) { "windowNs cannot be negative" }
    }

    fun tryAcquire(nowNs: Long): Boolean {
        while (
            recoveryTimesNs.isNotEmpty() &&
            nowNs - recoveryTimesNs.first() >= windowNs
        ) {
            recoveryTimesNs.removeFirst()
        }
        if (recoveryTimesNs.size >= maxRecoveries) return false
        recoveryTimesNs.addLast(nowNs)
        return true
    }

    fun clear() {
        recoveryTimesNs.clear()
    }
}
