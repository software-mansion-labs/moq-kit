@testable import MoQKit
import XCTest

final class PlaybackClockPolicyTests: XCTestCase {
    func testSmallErrorDoesNothing() {
        let controller = ClockRetargetController(policy: ClockPolicy())
        XCTAssertEqual(controller.decision(currentUs: 100_000, targetUs: 119_999), .noOp)
    }

    func testLargeErrorJumpsToTarget() {
        let controller = ClockRetargetController(policy: ClockPolicy())
        XCTAssertEqual(
            controller.decision(currentUs: 0, targetUs: 500_000),
            .jump(positionUs: 500_000)
        )
    }

    func testIntermediateErrorUsesBoundedRateNudge() {
        let controller = ClockRetargetController(policy: ClockPolicy())

        guard case .nudge(let faster) = controller.decision(
            currentUs: 100_000,
            targetUs: 200_000
        ) else {
            return XCTFail("Expected a faster nudge")
        }
        guard case .nudge(let slower) = controller.decision(
            currentUs: 200_000,
            targetUs: 100_000
        ) else {
            return XCTFail("Expected a slower nudge")
        }

        XCTAssertGreaterThan(faster, 1)
        XCTAssertLessThanOrEqual(faster, 1.05)
        XCTAssertLessThan(slower, 1)
        XCTAssertGreaterThanOrEqual(slower, 0.95)
    }
}
