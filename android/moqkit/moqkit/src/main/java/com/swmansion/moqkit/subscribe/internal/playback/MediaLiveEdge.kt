package com.swmansion.moqkit.subscribe.internal.playback

/**
 * Tracks the estimated live edge for one media stream from compressed-frame arrivals.
 */
internal class MediaLiveEdge(
    private val wallClockProvider: () -> Long = { System.nanoTime() / 1_000L },
) {
    private val lock = Any()
    private var maxOffset: Long? = null

    fun recordTimestamp(timestamp: Long) {
        val offset = try {
            Math.subtractExact(timestamp, wallClockProvider())
        } catch (_: ArithmeticException) {
            return
        }

        synchronized(lock) {
            maxOffset = maxOf(maxOffset ?: Long.MIN_VALUE, offset)
        }
    }

    fun reset() {
        synchronized(lock) {
            maxOffset = null
        }
    }

    fun estimatedLivePTS(): Long? {
        val offset = synchronized(lock) { maxOffset } ?: return null
        return try {
            Math.addExact(wallClockProvider(), offset)
        } catch (_: ArithmeticException) {
            null
        }
    }
}
