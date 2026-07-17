@testable import MoQKit
import XCTest

final class DisplayFeedSchedulerTests: XCTestCase {
    func testHoldsFrameBeyondFeedWindow() {
        let scheduler = DisplayFeedScheduler(policy: RenderPolicy(maxAheadUs: 500_000))

        XCTAssertEqual(
            scheduler.decision(
                framePtsUs: 1_000_001,
                playheadUs: 0,
                isPlaybackCandidate: true
            ),
            .hold(recheckAfterUs: 500_001)
        )
    }

    func testLateFrameIsFedDecodeOnlyOnIOS() {
        let scheduler = DisplayFeedScheduler(policy: RenderPolicy(lateDropThresholdUs: 50_000))

        XCTAssertEqual(
            scheduler.decision(
                framePtsUs: 100,
                playheadUs: 50_101,
                isPlaybackCandidate: true
            ),
            .decodeOnly
        )
    }

    func testFrameInsideWindowIsVisible() {
        let scheduler = DisplayFeedScheduler(policy: RenderPolicy())

        XCTAssertEqual(
            scheduler.decision(
                framePtsUs: 200_000,
                playheadUs: 100_000,
                isPlaybackCandidate: true
            ),
            .visible
        )
    }
}

final class RenditionSwitchControllerTests: XCTestCase {
    func testRecentKeyframeCutsInWhenActiveReachesIt() {
        let controller = RenditionSwitchController(policy: SwitchPolicy())
        controller.begin(targetTrack: "high", nowNanos: 0)

        XCTAssertEqual(
            controller.onKeyframeAvailable(activePtsUs: 1_000, keyframePtsUs: 1_100),
            .wait
        )
        XCTAssertEqual(controller.onActiveProgress(1_099), .wait)
        XCTAssertEqual(controller.onActiveProgress(1_100), .cutIn(keyframePtsUs: 1_100))
    }

    func testOldKeyframeRequiresFlushSwap() {
        let controller = RenditionSwitchController(
            policy: SwitchPolicy(flushThresholdUs: 2_000_000)
        )
        controller.begin(targetTrack: "high", nowNanos: 0)

        XCTAssertEqual(
            controller.onKeyframeAvailable(
                activePtsUs: 3_000_001,
                keyframePtsUs: 1_000_000
            ),
            .flushSwap
        )
    }

    func testPreparingSwitchAbortsAfterTimeout() {
        let controller = RenditionSwitchController(
            policy: SwitchPolicy(keyframeTimeoutUs: 5_000_000)
        )
        controller.begin(targetTrack: "high", nowNanos: 10)

        XCTAssertEqual(
            controller.onTime(nowNanos: 5_000_000_009),
            .wait
        )
        XCTAssertEqual(
            controller.onTime(nowNanos: 5_000_000_010),
            .abort(targetTrack: "high")
        )
    }

    func testCutInSwitchStillAbortsAfterOverallTimeout() {
        let controller = RenditionSwitchController(
            policy: SwitchPolicy(keyframeTimeoutUs: 5_000_000)
        )
        controller.begin(targetTrack: "high", nowNanos: 10)
        XCTAssertEqual(
            controller.onKeyframeAvailable(activePtsUs: 1_000, keyframePtsUs: 9_000_000),
            .wait
        )

        XCTAssertEqual(
            controller.onTime(nowNanos: 5_000_000_010),
            .abort(targetTrack: "high")
        )
    }
}

final class VideoRecoveryControllerTests: XCTestCase {
    func testDisplayRecoveryIsBoundedAndUsesFlushThenFail() {
        let time = MutablePipelineTimeSource()
        let controller = VideoRecoveryController(
            policy: RecoveryPolicy(maxRecoveries: 1),
            timeSource: time
        )

        XCTAssertEqual(controller.onFailure(trigger: "display failed").step, .flush)
        XCTAssertEqual(controller.onFailure(trigger: "failed again").step, .fail)
    }
}

final class AudioRecoveryControllerTests: XCTestCase {
    func testAudioRecoveryRebuildsConverterThenFailsAtBudget() {
        let time = MutablePipelineTimeSource()
        let controller = AudioRecoveryController(
            policy: RecoveryPolicy(maxRecoveries: 1),
            timeSource: time
        )

        XCTAssertEqual(controller.onFailure(trigger: "bad packet").step, .rebuild)
        XCTAssertEqual(controller.onFailure(trigger: "still bad").step, .fail)
    }
}

private final class MutablePipelineTimeSource: PipelineTimeSource, @unchecked Sendable {
    var nowNanos: UInt64 = 0
}
