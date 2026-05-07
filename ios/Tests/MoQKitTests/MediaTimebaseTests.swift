import CoreMedia
@testable import MoQKit
import XCTest

final class MediaLiveEdgeTests: XCTestCase {
    func testEstimatedTimeUsesMaxObservedOffset() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdge { wallClock.value }

        liveEdge.recordTimestamp(5_000)
        wallClock.value = 2_000
        liveEdge.recordTimestamp(5_500)
        wallClock.value = 10_000

        XCTAssertEqual(liveEdge.estimatedLivePTS(), 14_000)
    }

    func testLowerOffsetDoesNotMoveLiveEdgeBackward() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdge { wallClock.value }

        liveEdge.recordTimestamp(10_000)
        wallClock.value = 2_000
        liveEdge.recordTimestamp(9_000)
        wallClock.value = 5_000

        XCTAssertEqual(liveEdge.estimatedLivePTS(), 14_000)
    }

    func testResetClearsLiveEdge() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdge { wallClock.value }

        liveEdge.recordTimestamp(5_000)
        liveEdge.reset()

        XCTAssertNil(liveEdge.estimatedLivePTS())
    }

    func testInvalidTimestampIsIgnored() {
        let wallClock = WallClock(value: 1_000)
        let liveEdge = MediaLiveEdge { wallClock.value }

        liveEdge.recordTimestamp(UInt64(Int64.max) + 1)

        XCTAssertNil(liveEdge.estimatedLivePTS())
    }
}

final class MediaTimestampAlignerTests: XCTestCase {
    func testVideoOffsetRequiresAudioAndVideoLiveEdges() {
        let wallClock = WallClock(value: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))

        aligner.audioLiveEdge.recordTimestamp(11_000_000)
        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))

        aligner.videoLiveEdge.recordTimestamp(4_000_000)
        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), 7_000_000)
    }

    func testAlignedTimestampsReturnNoOpCorrection() {
        let wallClock = WallClock(value: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(5_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))
        XCTAssertEqual(aligner.audioTime(videoTime: 3_000_000, threshold: 2_000_000), 3_000_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 5_000_000, threshold: 2_000_000), 5_000_000)
    }

    func testDriftedVideoTimeMapsIntoAudioTime() {
        let wallClock = WallClock(value: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(6_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)

        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), 3_000_000)
        XCTAssertEqual(aligner.audioTime(videoTime: 10_000_000, threshold: 2_000_000), 13_000_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 13_000_000, threshold: 2_000_000), 10_000_000)
    }

    func testDriftedAudioTimeMapsBackIntoVideoTime() {
        let wallClock = WallClock(value: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(3_000_000)
        aligner.videoLiveEdge.recordTimestamp(6_500_000)

        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), -3_500_000)
        XCTAssertEqual(aligner.audioTime(videoTime: 10_000_000, threshold: 2_000_000), 6_500_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 6_500_000, threshold: 2_000_000), 10_000_000)
    }

    func testResetClearsAffectedTrackOffset() {
        let wallClock = WallClock(value: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(6_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)
        aligner.videoLiveEdge.reset()

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))
    }
}

final class MediaTimebaseTests: XCTestCase {
    func testSetTimeUpdatesCurrentTime() throws {
        let timebase = try makeMediaTimebase()

        timebase.setTimeUs(123_456)

        XCTAssertEqual(timebase.currentTime().value, 123_456, accuracy: 1)
        XCTAssertEqual(timebase.currentTime().timescale, 1_000_000)
        XCTAssertEqual(timebase.currentTimeUs, 123_456, accuracy: 1)
    }
}

private final class WallClock: @unchecked Sendable {
    var value: Int64

    init(value: Int64) {
        self.value = value
    }
}

private func makeMediaTimestampAligner(wallClock: WallClock) -> MediaTimestampAligner {
    MediaTimestampAligner(
        audioLiveEdge: MediaLiveEdge { wallClock.value },
        videoLiveEdge: MediaLiveEdge { wallClock.value }
    )
}

private func makeMediaTimebase() throws -> MediaTimebase {
    try MediaTimebase()
}
