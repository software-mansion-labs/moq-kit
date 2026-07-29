import Moq

/// A point-in-time snapshot of transport statistics for a relay connection.
///
/// Individual values are `nil` when the transport cannot report them or an estimate is not
/// available yet. A missing value is distinct from zero.
public struct ConnectionStats: Sendable, Equatable {
    /// The transport's smoothed round-trip time.
    public let roundTripTime: Duration?
    /// The congestion controller's estimated send capacity, in bits per second.
    public let estimatedSendRateBps: UInt64?
    /// The peer's estimated send capacity reported through MoQ PROBE, in bits per second.
    public let estimatedReceiveRateBps: UInt64?
    /// Total bytes sent by the transport, including retransmissions and overhead.
    public let bytesSent: UInt64?
    /// Total bytes received by the transport, including duplicates and overhead.
    public let bytesReceived: UInt64?
    /// Total bytes the transport detected as lost.
    public let bytesLost: UInt64?
    /// Total datagrams sent by the transport.
    public let packetsSent: UInt64?
    /// Total datagrams received by the transport.
    public let packetsReceived: UInt64?
    /// Total datagrams the transport detected as lost.
    public let packetsLost: UInt64?

    init(_ stats: Moq.ConnectionStats) {
        roundTripTime = stats.rttUs.map(Self.durationFromMicroseconds)
        estimatedSendRateBps = stats.sendRateBps
        estimatedReceiveRateBps = stats.recvRateBps
        bytesSent = stats.bytesSent
        bytesReceived = stats.bytesReceived
        bytesLost = stats.bytesLost
        packetsSent = stats.packetsSent
        packetsReceived = stats.packetsReceived
        packetsLost = stats.packetsLost
    }

    private static func durationFromMicroseconds(_ microseconds: UInt64) -> Duration {
        let seconds = microseconds / 1_000_000
        let remainingMicroseconds = microseconds % 1_000_000
        return Duration(
            secondsComponent: Int64(seconds),
            attosecondsComponent: Int64(remainingMicroseconds) * 1_000_000_000_000
        )
    }
}
