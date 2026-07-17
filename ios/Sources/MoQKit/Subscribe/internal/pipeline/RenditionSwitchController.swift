import Foundation

enum RenditionSwitchState: Equatable {
    case steady
    case preparing(targetTrack: String, startedNanos: UInt64)
    case cuttingIn(targetTrack: String, keyframePtsUs: UInt64)
    case flushSwap(targetTrack: String)
}

enum RenditionSwitchDecision: Equatable {
    case wait
    case cutIn(keyframePtsUs: UInt64)
    case flushSwap
    case abort(targetTrack: String)
}

/// Pure authority for rendition switch phase, cut-in, flush, and timeout decisions.
final class RenditionSwitchController {
    private let policy: SwitchPolicy
    private var switchStartedNanos: UInt64?

    private(set) var state: RenditionSwitchState = .steady

    init(policy: SwitchPolicy = PipelinePolicies.switch) {
        self.policy = policy
    }

    func begin(targetTrack: String, nowNanos: UInt64) {
        precondition(!targetTrack.isEmpty, "target track must not be empty")
        switchStartedNanos = nowNanos
        state = .preparing(targetTrack: targetTrack, startedNanos: nowNanos)
    }

    func onKeyframeAvailable(
        activePtsUs: UInt64,
        keyframePtsUs: UInt64
    ) -> RenditionSwitchDecision {
        guard case .preparing(let target, _) = state else { return .wait }
        let gap = activePtsUs > keyframePtsUs ? activePtsUs - keyframePtsUs : 0
        if gap > UInt64(policy.flushThresholdUs) {
            state = .flushSwap(targetTrack: target)
            return .flushSwap
        }
        state = .cuttingIn(targetTrack: target, keyframePtsUs: keyframePtsUs)
        return .wait
    }

    func onActiveProgress(_ activePtsUs: UInt64) -> RenditionSwitchDecision {
        switch state {
        case .cuttingIn(_, let keyframePtsUs) where activePtsUs >= keyframePtsUs:
            return .cutIn(keyframePtsUs: keyframePtsUs)
        case .flushSwap:
            return .flushSwap
        default:
            return .wait
        }
    }

    func onTime(nowNanos: UInt64) -> RenditionSwitchDecision {
        let target: String
        switch state {
        case .preparing(let targetTrack, _), .cuttingIn(let targetTrack, _):
            target = targetTrack
        case .steady, .flushSwap:
            return .wait
        }
        guard let started = switchStartedNanos else { return .wait }
        let elapsed = nowNanos >= started ? nowNanos - started : 0
        guard elapsed >= UInt64(policy.keyframeTimeoutUs) * 1_000 else { return .wait }
        switchStartedNanos = nil
        state = .steady
        return .abort(targetTrack: target)
    }

    func shouldDiscardPendingDelta(activePtsUs: UInt64, framePtsUs: UInt64) -> Bool {
        activePtsUs > framePtsUs
            && activePtsUs - framePtsUs > UInt64(policy.cutInWindowUs)
    }

    func complete() {
        switchStartedNanos = nil
        state = .steady
    }
}
