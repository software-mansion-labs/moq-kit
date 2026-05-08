import CoreMedia
@testable import MoQKit
import XCTest

final class MediaLiveEdgeTests: XCTestCase {
    func testEstimatedTimeUsesMaxObservedOffset() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let liveEdge = MediaLiveEdge(wallClock: wallClock)

        liveEdge.recordTimestamp(5_000)
        wallClock.setMicroseconds(2_000)
        liveEdge.recordTimestamp(5_500)
        wallClock.setMicroseconds(10_000)

        XCTAssertEqual(liveEdge.estimatedLivePTS(), 14_000)
    }

    func testLowerOffsetDoesNotMoveLiveEdgeBackward() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let liveEdge = MediaLiveEdge(wallClock: wallClock)

        liveEdge.recordTimestamp(10_000)
        wallClock.setMicroseconds(2_000)
        liveEdge.recordTimestamp(9_000)
        wallClock.setMicroseconds(5_000)

        XCTAssertEqual(liveEdge.estimatedLivePTS(), 14_000)
    }

    func testResetClearsLiveEdge() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let liveEdge = MediaLiveEdge(wallClock: wallClock)

        liveEdge.recordTimestamp(5_000)
        liveEdge.reset()

        XCTAssertNil(liveEdge.estimatedLivePTS())
    }

    func testInvalidTimestampIsIgnored() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let liveEdge = MediaLiveEdge(wallClock: wallClock)

        liveEdge.recordTimestamp(UInt64(Int64.max) + 1)

        XCTAssertNil(liveEdge.estimatedLivePTS())
    }
}

final class MediaTimestampAlignerTests: XCTestCase {
    func testVideoOffsetRequiresAudioAndVideoLiveEdges() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))

        aligner.audioLiveEdge.recordTimestamp(11_000_000)
        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))

        aligner.videoLiveEdge.recordTimestamp(4_000_000)
        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), 7_000_000)
    }

    func testAlignedTimestampsReturnNoOpCorrection() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(5_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))
        XCTAssertEqual(aligner.audioTime(videoTime: 3_000_000, threshold: 2_000_000), 3_000_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 5_000_000, threshold: 2_000_000), 5_000_000)
    }

    func testDriftedVideoTimeMapsIntoAudioTime() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(6_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)

        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), 3_000_000)
        XCTAssertEqual(aligner.audioTime(videoTime: 10_000_000, threshold: 2_000_000), 13_000_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 13_000_000, threshold: 2_000_000), 10_000_000)
    }

    func testDriftedAudioTimeMapsBackIntoVideoTime() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(3_000_000)
        aligner.videoLiveEdge.recordTimestamp(6_500_000)

        XCTAssertEqual(aligner.videoOffset(threshold: 2_000_000), -3_500_000)
        XCTAssertEqual(aligner.audioTime(videoTime: 10_000_000, threshold: 2_000_000), 6_500_000)
        XCTAssertEqual(aligner.videoTime(audioTime: 6_500_000, threshold: 2_000_000), 10_000_000)
    }

    func testResetClearsAffectedTrackOffset() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000_000)
        let aligner = makeMediaTimestampAligner(wallClock: wallClock)

        aligner.audioLiveEdge.recordTimestamp(6_000_000)
        aligner.videoLiveEdge.recordTimestamp(3_000_000)
        aligner.videoLiveEdge.reset()

        XCTAssertNil(aligner.videoOffset(threshold: 2_000_000))
    }
}

final class AudioDrivenClockTests: XCTestCase {
    func testSetTimeUpdatesCurrentTime() throws {
        let timebase = try makeAudioDrivenClock()

        timebase.setTimeUs(123_456)

        XCTAssertEqual(timebase.currentTime().value, 123_456, accuracy: 1)
        XCTAssertEqual(timebase.currentTime().timescale, 1_000_000)
        XCTAssertEqual(timebase.currentTimeUs, 123_456, accuracy: 1)
    }
}

final class JitterBufferTests: XCTestCase {
    func testTargetPlaybackPTSUsesEstimatedLiveEdgeMinusTargetBuffering() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let buffer = JitterBuffer<Int>(targetBufferingUs: 1_000, wallClock: wallClock)

        buffer.insert(item: 1, timestampUs: 10_000)
        wallClock.setMicroseconds(2_000)
        buffer.insert(item: 2, timestampUs: 11_000)
        wallClock.setMicroseconds(2_500)

        XCTAssertEqual(buffer.state, .playing)
        XCTAssertEqual(buffer.estimatedLivePTS(), 11_500)
        XCTAssertEqual(buffer.targetPlaybackPTS(), 10_500)
        XCTAssertEqual(buffer.frontFrameIntervalUs, 1_000)

        let (entry, playable) = buffer.dequeue()
        XCTAssertEqual(entry?.timestampUs, 10_000)
        XCTAssertFalse(playable)
    }

    func testUpdatingTargetBufferingCanStartBufferedMedia() {
        let wallClock = TestPlaybackWallClock(nowUs: 0)
        let buffer = JitterBuffer<Int>(targetBufferingUs: 2_000, wallClock: wallClock)

        buffer.insert(item: 1, timestampUs: 1_000)
        buffer.insert(item: 2, timestampUs: 2_000)

        XCTAssertEqual(buffer.state, .buffering)
        XCTAssertTrue(buffer.updateTargetBuffering(us: 1_000))
        XCTAssertEqual(buffer.state, .playing)
    }

    func testEstimatedLiveEdgeKeepsMaximumObservedOffset() {
        let wallClock = TestPlaybackWallClock(nowUs: 1_000)
        let buffer = JitterBuffer<Int>(targetBufferingUs: 1_000, wallClock: wallClock)

        buffer.insert(item: 1, timestampUs: 10_000)
        wallClock.setMicroseconds(2_000)
        buffer.insert(item: 2, timestampUs: 9_000)
        wallClock.setMicroseconds(5_000)

        XCTAssertEqual(buffer.estimatedLivePTS(), 14_000)
        XCTAssertEqual(buffer.targetPlaybackPTS(), 13_000)
    }
}

private func makeMediaTimestampAligner(wallClock: TestPlaybackWallClock) -> MediaTimestampAligner {
    MediaTimestampAligner(
        audioLiveEdge: MediaLiveEdge(wallClock: wallClock),
        videoLiveEdge: MediaLiveEdge(wallClock: wallClock)
    )
}

private func makeAudioDrivenClock() throws -> AudioDrivenClock {
    try AudioDrivenClock()
}
