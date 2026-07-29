@testable import MoQKit
import Moq
import XCTest

final class ConnectionStatsTests: XCTestCase {
    func testMapsNativeConnectionStats() {
        let native = Moq.ConnectionStats(
            rttUs: 12_345,
            sendRateBps: 8_000_000,
            recvRateBps: 6_000_000,
            bytesSent: 101,
            bytesReceived: 202,
            bytesLost: 3,
            packetsSent: 11,
            packetsReceived: 22,
            packetsLost: 1
        )

        let stats = MoQKit.ConnectionStats(native)

        XCTAssertEqual(stats.roundTripTime, Duration.microseconds(12_345))
        XCTAssertEqual(stats.estimatedSendRateBps, 8_000_000)
        XCTAssertEqual(stats.estimatedReceiveRateBps, 6_000_000)
        XCTAssertEqual(stats.bytesSent, 101)
        XCTAssertEqual(stats.bytesReceived, 202)
        XCTAssertEqual(stats.bytesLost, 3)
        XCTAssertEqual(stats.packetsSent, 11)
        XCTAssertEqual(stats.packetsReceived, 22)
        XCTAssertEqual(stats.packetsLost, 1)
    }

    func testPreservesUnavailableNativeMetrics() {
        let native = Moq.ConnectionStats(
            rttUs: nil,
            sendRateBps: nil,
            recvRateBps: nil,
            bytesSent: nil,
            bytesReceived: nil,
            bytesLost: nil,
            packetsSent: nil,
            packetsReceived: nil,
            packetsLost: nil
        )

        let stats = MoQKit.ConnectionStats(native)

        XCTAssertNil(stats.roundTripTime)
        XCTAssertNil(stats.estimatedSendRateBps)
        XCTAssertNil(stats.estimatedReceiveRateBps)
        XCTAssertNil(stats.bytesSent)
        XCTAssertNil(stats.bytesReceived)
        XCTAssertNil(stats.bytesLost)
        XCTAssertNil(stats.packetsSent)
        XCTAssertNil(stats.packetsReceived)
        XCTAssertNil(stats.packetsLost)
    }

    func testMapsRoundTripTimeWithoutOverflowingMicroseconds() {
        let native = Moq.ConnectionStats(
            rttUs: UInt64.max,
            sendRateBps: nil,
            recvRateBps: nil,
            bytesSent: nil,
            bytesReceived: nil,
            bytesLost: nil,
            packetsSent: nil,
            packetsReceived: nil,
            packetsLost: nil
        )

        let stats = MoQKit.ConnectionStats(native)
        let expected = Duration(
            secondsComponent: 18_446_744_073_709,
            attosecondsComponent: 551_615_000_000_000_000
        )

        XCTAssertEqual(stats.roundTripTime, expected)
    }
}
