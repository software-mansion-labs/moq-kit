@testable import MoQKit
import Foundation
import XCTest

final class PlaybackStatsTrackerTests: XCTestCase {
    func testReceivedBytesProduceAudioBitrate() {
        let clock = TestClock()
        let tracker = PlaybackStatsTracker(clock: { clock.nowNs })

        tracker.onMediaFrame(mediaFrame(payloadSize: 100, timestampUs: 0), kind: .audio)
        clock.advance(ms: 200)
        tracker.onMediaFrame(mediaFrame(payloadSize: 100, timestampUs: 200_000), kind: .audio)

        let stats = tracker.snapshot(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        XCTAssertEqual(stats.audioBitrateKbps ?? 0, 8.0, accuracy: 0.001)
        XCTAssertNil(stats.videoBitrateKbps)
    }

    func testFirstFrameTimingIsMarkedOncePerKind() {
        let clock = TestClock(nowNs: 1_000_000_000)
        let tracker = PlaybackStatsTracker(clock: { clock.nowNs })

        tracker.markPlayStart()
        clock.advance(ms: 100)
        tracker.onMediaFrame(mediaFrame(timestampUs: 0), kind: .video)
        clock.advance(ms: 300)
        tracker.onMediaFrame(mediaFrame(timestampUs: 300_000), kind: .video)

        let stats = tracker.snapshot(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        XCTAssertEqual(stats.timeToFirstVideoFrameMs ?? 0, 100, accuracy: 0.001)
        XCTAssertNil(stats.timeToFirstAudioFrameMs)
    }

    func testArrivalWindowReportsReceivedFpsAndInterarrivalTiming() throws {
        let clock = TestClock()
        let tracker = PlaybackStatsTracker(clock: { clock.nowNs })

        tracker.onMediaFrame(mediaFrame(timestampUs: 0), kind: .video)
        clock.advance(ms: 100)
        tracker.onMediaFrame(mediaFrame(timestampUs: 100_000), kind: .video)
        clock.advance(ms: 100)
        tracker.onMediaFrame(mediaFrame(timestampUs: 200_000), kind: .video)

        let stats = tracker.snapshot(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.receivedFramesPerSecond ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(arrival.averageInterarrivalMs ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(arrival.maxInterarrivalMs ?? 0, 100.0, accuracy: 0.001)
    }

    func testArrivalDiagnosticsTrackGapsBurstsAndOutOfOrderFrames() throws {
        let clock = TestClock()
        let tracker = PlaybackStatsTracker(clock: { clock.nowNs })

        tracker.onMediaFrame(mediaFrame(timestampUs: 0), kind: .audio)
        clock.advance(ms: 100)
        tracker.onMediaFrame(mediaFrame(timestampUs: 100_000), kind: .audio)
        clock.advance(ms: 250)
        tracker.onMediaFrame(mediaFrame(timestampUs: 200_000), kind: .audio)
        clock.advance(ms: 10)
        tracker.onMediaFrame(mediaFrame(timestampUs: 300_000), kind: .audio)
        clock.advance(ms: 10)
        tracker.onMediaFrame(mediaFrame(timestampUs: 250_000), kind: .audio)

        let stats = tracker.snapshot(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.audioArrival)
        XCTAssertEqual(arrival.arrivalGapCount, 1)
        XCTAssertEqual(arrival.burstCount, 1)
        XCTAssertEqual(arrival.outOfOrderCount, 1)
        XCTAssertEqual(arrival.maxOutOfOrderDeltaMs ?? 0, 50.0, accuracy: 0.001)
    }

    func testFrameDiscontinuityResetsIntervalBaselineAndTracksGap() throws {
        let clock = TestClock()
        let tracker = PlaybackStatsTracker(clock: { clock.nowNs })

        tracker.onMediaFrame(mediaFrame(timestampUs: 0), kind: .video)
        tracker.onFrameDiscontinuity(kind: .video, gapUs: 700_000)
        clock.advance(ms: 700)
        tracker.onMediaFrame(mediaFrame(timestampUs: 700_000, keyframe: true), kind: .video)

        let stats = tracker.snapshot(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.discontinuityCount, 1)
        XCTAssertEqual(arrival.maxDiscontinuityGapMs ?? 0, 700.0, accuracy: 0.001)
        XCTAssertEqual(arrival.arrivalGapCount, 0)
        XCTAssertNil(arrival.averageInterarrivalMs)
    }
}

private final class TestClock: @unchecked Sendable {
    var nowNs: UInt64

    init(nowNs: UInt64 = 0) {
        self.nowNs = nowNs
    }

    func advance(ms: UInt64) {
        nowNs += ms * 1_000_000
    }
}

private func mediaFrame(
    payloadSize: Int = 1,
    timestampUs: UInt64,
    keyframe: Bool = false
) -> MediaFrame {
    MediaFrame(payload: Data(repeating: 0, count: payloadSize), timestampUs: timestampUs, keyframe: keyframe)
}
