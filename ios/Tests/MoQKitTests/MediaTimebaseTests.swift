import CoreMedia
@testable import MoQKit
import XCTest

final class AudioDrivenClockTests: XCTestCase {
    func testSetTimeUpdatesCurrentTime() throws {
        let timebase = try makeAudioDrivenClock()

        timebase.setTimeUs(123_456)

        XCTAssertEqual(timebase.currentTime().value, 123_456, accuracy: 1)
        XCTAssertEqual(timebase.currentTime().timescale, 1_000_000)
        XCTAssertEqual(timebase.currentTimeUs, 123_456, accuracy: 1)
    }
}

private func makeAudioDrivenClock() throws -> AudioDrivenClock {
    try AudioDrivenClock()
}
