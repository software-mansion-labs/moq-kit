package com.swmansion.moqkit

import dev.moq.ConnectionStats as NativeConnectionStats
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionStatsTest {
    @Test
    fun mapsNativeConnectionStats() {
        val native = NativeConnectionStats(
            rttUs = 12_345u,
            sendRateBps = 8_000_000u,
            recvRateBps = 6_000_000u,
            bytesSent = 101u,
            bytesReceived = 202u,
            bytesLost = 3u,
            packetsSent = 11u,
            packetsReceived = 22u,
            packetsLost = 1u,
        )

        val stats = native.toConnectionStats()

        assertEquals(Duration.ofNanos(12_345_000), stats.roundTripTime)
        assertEquals(8_000_000uL, stats.estimatedSendRateBps)
        assertEquals(6_000_000uL, stats.estimatedReceiveRateBps)
        assertEquals(101uL, stats.bytesSent)
        assertEquals(202uL, stats.bytesReceived)
        assertEquals(3uL, stats.bytesLost)
        assertEquals(11uL, stats.packetsSent)
        assertEquals(22uL, stats.packetsReceived)
        assertEquals(1uL, stats.packetsLost)
    }

    @Test
    fun preservesUnavailableNativeMetrics() {
        val native = NativeConnectionStats(
            rttUs = null,
            sendRateBps = null,
            recvRateBps = null,
            bytesSent = null,
            bytesReceived = null,
            bytesLost = null,
            packetsSent = null,
            packetsReceived = null,
            packetsLost = null,
        )

        val stats = native.toConnectionStats()

        assertNull(stats.roundTripTime)
        assertNull(stats.estimatedSendRateBps)
        assertNull(stats.estimatedReceiveRateBps)
        assertNull(stats.bytesSent)
        assertNull(stats.bytesReceived)
        assertNull(stats.bytesLost)
        assertNull(stats.packetsSent)
        assertNull(stats.packetsReceived)
        assertNull(stats.packetsLost)
    }

    @Test
    fun mapsRoundTripTimeWithoutOverflowingMicroseconds() {
        val native = NativeConnectionStats(
            rttUs = ULong.MAX_VALUE,
            sendRateBps = null,
            recvRateBps = null,
            bytesSent = null,
            bytesReceived = null,
            bytesLost = null,
            packetsSent = null,
            packetsReceived = null,
            packetsLost = null,
        )

        val stats = native.toConnectionStats()
        val expected = Duration.ofSeconds(18_446_744_073_709, 551_615_000)

        assertEquals(expected, stats.roundTripTime)
    }
}
