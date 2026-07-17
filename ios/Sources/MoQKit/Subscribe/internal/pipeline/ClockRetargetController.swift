import Foundation

/// Pure bounded retarget policy shared by playback clock drivers.
struct ClockRetargetController: Sendable {
    let policy: ClockPolicy

    init(policy: ClockPolicy = PipelinePolicies.clock) {
        self.policy = policy
    }

    func decision(currentUs: UInt64, targetUs: UInt64) -> RetargetDecision {
        let error: Int64
        if targetUs >= currentUs {
            error = Int64(clamping: targetUs - currentUs)
        } else {
            error = -Int64(clamping: currentUs - targetUs)
        }
        let magnitude = error == .min ? Int64.max : abs(error)
        if magnitude <= policy.retargetToleranceUs {
            return .noOp
        }
        if magnitude >= policy.jumpThresholdUs {
            return .jump(positionUs: Int64(clamping: targetUs))
        }

        let fraction = min(
            1,
            Double(magnitude - policy.retargetToleranceUs)
                / Double(max(1, policy.jumpThresholdUs - policy.retargetToleranceUs))
        )
        if error > 0 {
            return .nudge(rate: 1 + (policy.maxRate - 1) * fraction)
        }
        return .nudge(rate: 1 - (1 - policy.minRate) * fraction)
    }
}
