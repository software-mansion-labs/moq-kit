@testable import MoQKit
import XCTest

final class TrackTimelineTests: XCTestCase {
    func testDownstreamResetClearsLiveEdgeUntilAnotherFrameArrives() {
        let time = TestPipelineTimeSource(nowNanos: 1_000_000)
        let timeline = TrackTimeline(timeSource: time)
        _ = timeline.onFrame(timedFrame(timestampUs: 5_000, epoch: 1))

        let reset: TimelineDecision<String> = timeline.requestReset()

        XCTAssertNil(timeline.liveEdgeUs())
        guard case .reset(let reason, let epoch, nil, nil) = reset else {
            return XCTFail("Expected a downstream timeline reset")
        }
        XCTAssertEqual(reason, .downstreamRecovery)
        XCTAssertEqual(epoch, 1)
    }

    func testTimestampGapOnDeltaFrameResetsTimeline() {
        let time = TestPipelineTimeSource(nowNanos: 1_000_000)
        let timeline = TrackTimeline(policy: TimelinePolicy(), timeSource: time)

        XCTAssertAdmitted(timeline.onFrame(timedFrame(timestampUs: 100, keyframe: true)))
        let decision = timeline.onFrame(timedFrame(timestampUs: 600_101))

        guard case .reset(let reason, let epoch, let resumeFrom, let gapUs) = decision else {
            return XCTFail("Expected a timeline reset")
        }
        XCTAssertEqual(reason, .timestampGap)
        XCTAssertEqual(epoch, 1)
        XCTAssertEqual(resumeFrom?.timestampUs, 600_101)
        XCTAssertEqual(gapUs, 600_001)
    }

    func testFrameOlderThanFreshnessBudgetIsRejected() {
        let timeline = TrackTimeline(
            policy: TimelinePolicy(freshnessBudgetUs: 100),
            timeSource: TestPipelineTimeSource()
        )
        timeline.onPlaybackPosition(1_000)

        let decision = timeline.onFrame(timedFrame(timestampUs: 899, keyframe: true))

        guard case .drop(let reason, let frame) = decision else {
            return XCTFail("Expected stale frame drop")
        }
        XCTAssertEqual(reason, .staleVsPlayback)
        XCTAssertEqual(frame.timestampUs, 899)
    }

    func testEpochChangeResetsAndRetainsResumeFrame() {
        let timeline = TrackTimeline(
            policy: TimelinePolicy(),
            timeSource: TestPipelineTimeSource()
        )
        XCTAssertAdmitted(timeline.onFrame(timedFrame(timestampUs: 1_000, epoch: 1)))

        let decision = timeline.onFrame(timedFrame(timestampUs: 10, epoch: 2))

        guard case .reset(let reason, let epoch, let resumeFrom, _) = decision else {
            return XCTFail("Expected publisher rewind reset")
        }
        XCTAssertEqual(reason, .publisherRewind)
        XCTAssertEqual(epoch, 2)
        XCTAssertEqual(resumeFrom?.timestampUs, 10)
    }

    func testLiveEdgeKeepsMaximumObservedTimestampOffset() {
        let time = TestPipelineTimeSource(nowNanos: 1_000_000)
        let timeline = TrackTimeline(policy: TimelinePolicy(), timeSource: time)
        XCTAssertAdmitted(timeline.onFrame(
            timedFrame(timestampUs: 10_000),
            arrivalNanos: time.nowNanos
        ))
        time.nowNanos = 2_000_000
        XCTAssertAdmitted(timeline.onFrame(
            timedFrame(timestampUs: 9_000),
            arrivalNanos: time.nowNanos
        ))

        time.nowNanos = 5_000_000

        XCTAssertEqual(timeline.liveEdgeUs(), 14_000)
    }

    func testTimestampMapperUsesCurrentTimelineLiveEdges() {
        let time = TestPipelineTimeSource(nowNanos: 1_000_000_000)
        let audio = TrackTimeline(policy: TimelinePolicy(), timeSource: time)
        let video = TrackTimeline(policy: TimelinePolicy(), timeSource: time)
        XCTAssertAdmitted(audio.onFrame(timedFrame(timestampUs: 6_000_000)))
        XCTAssertAdmitted(video.onFrame(timedFrame(timestampUs: 3_000_000)))
        let mapper = TimestampDomainMapper(audioTimeline: audio, videoTimeline: video)

        XCTAssertEqual(mapper.videoOffsetUs(thresholdUs: 2_000_000), 3_000_000)
        XCTAssertEqual(
            mapper.audioTimeUs(videoTimeUs: 10_000_000, thresholdUs: 2_000_000),
            13_000_000
        )
        XCTAssertEqual(
            mapper.videoTimeUs(audioTimeUs: 13_000_000, thresholdUs: 2_000_000),
            10_000_000
        )
    }

    private func XCTAssertAdmitted(
        _ decision: TimelineDecision<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .admit = decision else {
            return XCTFail("Expected admitted frame", file: file, line: line)
        }
    }
}

private final class TestPipelineTimeSource: PipelineTimeSource, @unchecked Sendable {
    var nowNanos: UInt64

    init(nowNanos: UInt64 = 0) {
        self.nowNanos = nowNanos
    }
}

private func timedFrame(
    timestampUs: Int64,
    keyframe: Bool = false,
    epoch: UInt64 = 1
) -> PipelineFrame<String> {
    PipelineFrame(
        payload: "frame",
        timestampUs: timestampUs,
        keyframe: keyframe,
        sizeBytes: 1,
        epoch: epoch
    )
}
