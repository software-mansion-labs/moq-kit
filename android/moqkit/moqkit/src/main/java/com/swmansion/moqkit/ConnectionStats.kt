package com.swmansion.moqkit

import dev.moq.ConnectionStats as NativeConnectionStats
import java.time.Duration

/**
 * A point-in-time snapshot of transport statistics for a relay connection.
 *
 * Individual values are `null` when the transport cannot report them or an estimate is not
 * available yet. A missing value is distinct from zero.
 */
@ConsistentCopyVisibility
data class ConnectionStats internal constructor(
    /** The transport's smoothed round-trip time. */
    val roundTripTime: Duration?,
    /** The congestion controller's estimated send capacity, in bits per second. */
    val estimatedSendRateBps: ULong?,
    /** The peer's estimated send capacity reported through MoQ PROBE, in bits per second. */
    val estimatedReceiveRateBps: ULong?,
    /** Total bytes sent by the transport, including retransmissions and overhead. */
    val bytesSent: ULong?,
    /** Total bytes received by the transport, including duplicates and overhead. */
    val bytesReceived: ULong?,
    /** Total bytes the transport detected as lost. */
    val bytesLost: ULong?,
    /** Total datagrams sent by the transport. */
    val packetsSent: ULong?,
    /** Total datagrams received by the transport. */
    val packetsReceived: ULong?,
    /** Total datagrams the transport detected as lost. */
    val packetsLost: ULong?,
)

internal fun NativeConnectionStats.toConnectionStats() = ConnectionStats(
    roundTripTime = rttUs?.let(::durationFromMicroseconds),
    estimatedSendRateBps = sendRateBps,
    estimatedReceiveRateBps = recvRateBps,
    bytesSent = bytesSent,
    bytesReceived = bytesReceived,
    bytesLost = bytesLost,
    packetsSent = packetsSent,
    packetsReceived = packetsReceived,
    packetsLost = packetsLost,
)

private fun durationFromMicroseconds(microseconds: ULong): Duration = Duration.ofSeconds(
    (microseconds / MICROSECONDS_PER_SECOND).toLong(),
    ((microseconds % MICROSECONDS_PER_SECOND) * NANOSECONDS_PER_MICROSECOND).toLong(),
)

private const val MICROSECONDS_PER_SECOND = 1_000_000uL
private const val NANOSECONDS_PER_MICROSECOND = 1_000uL
