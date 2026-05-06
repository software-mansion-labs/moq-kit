import CoreMedia
@testable import MoQKit
import XCTest

final class MediaLiveEdgeOffsetTests: XCTestCase {
    func testEstimatedLivePtsUsesMaxObservedOffset() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdgeOffset { wallClock.value }

        liveEdge.recordTimestamp(5_000)
        wallClock.value = 2_000
        liveEdge.recordTimestamp(5_500)
        wallClock.value = 10_000

        XCTAssertEqual(liveEdge.estimatedLivePtsUs, 14_000)
    }

    func testLowerOffsetDoesNotMoveLiveEdgeBackward() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdgeOffset { wallClock.value }

        liveEdge.recordTimestamp(10_000)
        wallClock.value = 2_000
        liveEdge.recordTimestamp(9_000)
        wallClock.value = 5_000

        XCTAssertEqual(liveEdge.estimatedLivePtsUs, 14_000)
    }

    func testResetClearsLiveEdge() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdgeOffset { wallClock.value }

        liveEdge.recordTimestamp(5_000)
        liveEdge.reset()

        XCTAssertNil(liveEdge.estimatedLivePtsUs)
    }

    func testInvalidTimestampIsIgnored() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdgeOffset { wallClock.value }

        liveEdge.recordTimestamp(UInt64(Int64.max) + 1)

        XCTAssertNil(liveEdge.estimatedLivePtsUs)
    }
}

final class MediaTimebaseTests: XCTestCase {
    func testEstimatedLivePtsDifferenceUsesAudioMinusVideoLiveEdges() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(11_000_000)
        timebase.videoLiveEdge.recordTimestamp(4_000_000)

        XCTAssertEqual(timebase.estimatedLivePtsDifferenceUs(), 7_000_000)
    }

    func testVideoPtsCorrectionRequiresBothAudioAndVideoEstimates() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(5_000_000)

        XCTAssertNil(timebase.videoPtsCorrectionUs(thresholdUs: 2_000_000))
    }

    func testVideoPtsCorrectionDoesNotTriggerAtThreshold() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(5_000_000)
        timebase.videoLiveEdge.recordTimestamp(3_000_000)

        XCTAssertNil(timebase.videoPtsCorrectionUs(thresholdUs: 2_000_000))
    }

    func testVideoPtsCorrectionTriggersWhenAudioLivePtsIsAhead() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(6_000_000)
        timebase.videoLiveEdge.recordTimestamp(3_000_000)

        let correction = timebase.videoPtsCorrection(
            forSourceTimestampUs: 10_000_000,
            thresholdUs: 2_000_000)

        XCTAssertEqual(correction, .init(offsetUs: 3_000_000, correctedTimestampUs: 13_000_000))
    }

    func testVideoPtsCorrectionTriggersWhenVideoLivePtsIsAhead() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(3_000_000)
        timebase.videoLiveEdge.recordTimestamp(6_500_000)

        let correction = timebase.videoPtsCorrection(
            forSourceTimestampUs: 10_000_000,
            thresholdUs: 2_000_000)

        XCTAssertEqual(correction, .init(offsetUs: -3_500_000, correctedTimestampUs: 6_500_000))
    }

    func testVideoPtsCorrectionSkipsNegativeAdjustedTimestamp() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(1_000_000)
        timebase.videoLiveEdge.recordTimestamp(6_000_000)

        XCTAssertNil(timebase.videoPtsCorrection(
            forSourceTimestampUs: 1_000_000,
            thresholdUs: 2_000_000))
    }

    func testAudioLatencyUsesEstimatedAudioLivePts() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(6_000_000)
        timebase.setTimeUs(4_500_000)

        XCTAssertEqual(timebase.audioLatencyMs(), 1_500)
    }

    func testVideoLatencyUsesNormalizedVideoPtsWhenCorrectionApplies() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(6_000_000)
        timebase.videoLiveEdge.recordTimestamp(3_000_000)
        timebase.setTimeUs(4_500_000)

        XCTAssertEqual(timebase.videoLatencyMs(thresholdUs: 2_000_000), 1_500)
    }

    func testVideoLatencyUsesRawVideoLivePtsWhenCorrectionDoesNotApply() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(5_000_000)
        timebase.videoLiveEdge.recordTimestamp(4_500_000)
        timebase.setTimeUs(4_000_000)

        XCTAssertEqual(timebase.videoLatencyMs(thresholdUs: 2_000_000), 500)
    }

    func testVideoLatencyIsNilUntilVideoLiveEdgeExists() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(6_000_000)
        timebase.setTimeUs(4_000_000)

        XCTAssertNil(timebase.videoLatencyMs(thresholdUs: 2_000_000))
    }

    func testResetClearsAffectedTrackOffset() throws {
        let wallClock = WallClock(value: 1_000_000)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.audioLiveEdge.recordTimestamp(6_000_000)
        timebase.videoLiveEdge.recordTimestamp(3_000_000)
        timebase.videoLiveEdge.reset()

        XCTAssertNil(timebase.estimatedLivePtsDifferenceUs())
        XCTAssertNil(timebase.videoPtsCorrectionUs(thresholdUs: 2_000_000))
    }

    func testSetTimeUpdatesOwnedCMTimebase() throws {
        let wallClock = WallClock(value: 0)
        let timebase = try makeMediaTimebase(wallClock: wallClock)

        timebase.setTimeUs(123_456)

        XCTAssertEqual(timebase.currentTimeUs, 123_456, accuracy: 1)
    }
}

private final class WallClock: @unchecked Sendable {
    var value: Int64

    init(value: Int64) {
        self.value = value
    }
}

private func makeMediaTimebase(wallClock: WallClock) throws -> MediaTimebase {
    var rawTimebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: CMClockGetHostTimeClock(),
        timebaseOut: &rawTimebase
    )
    let unwrapped = try XCTUnwrap(rawTimebase)
    CMTimebaseSetTime(unwrapped, time: .zero)
    CMTimebaseSetRate(unwrapped, rate: 0)

    return MediaTimebase(
        cmTimebase: unwrapped,
        audioLiveEdge: MediaLiveEdgeOffset { wallClock.value },
        videoLiveEdge: MediaLiveEdgeOffset { wallClock.value }
    )
}
