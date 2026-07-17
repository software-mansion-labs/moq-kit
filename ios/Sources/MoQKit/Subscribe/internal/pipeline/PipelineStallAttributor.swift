import Foundation

/// Central per-track stall attribution. Producers report that progress stopped; this
/// authority chooses the most-upstream known cause from pipeline events.
final class PipelineStallAttributor: @unchecked Sendable {
    private struct Key: Hashable {
        let trackId: String
        let mediaKind: PipelineMediaKind
    }

    private struct State {
        var lastArrivalNanos: UInt64?
        var lastAdmitNanos: UInt64?
        var lastPolicyDropNanos: UInt64?
        var depth = BufferDepth.empty
        var receiveBitsPerSecond: UInt64?
        var switchPhase = SwitchPhase.steady
    }

    private let lock = UnfairLock()
    private let policy: StallPolicy
    private var states: [Key: State] = [:]
    private var observation: PipelineObservation?

    init(bus: PipelineBus, policy: StallPolicy = PipelinePolicies.stall) {
        self.policy = policy
        self.observation = bus.observe { [weak self] event in
            self?.onEvent(event)
        }
    }

    func cause(
        trackId: String,
        mediaKind: PipelineMediaKind,
        nowNanos: UInt64,
        fallback: StallCause
    ) -> StallCause {
        lock.withLock {
            guard let state = states[Key(trackId: trackId, mediaKind: mediaKind)] else {
                return fallback
            }
            if state.switchPhase == .preparing {
                return .switchStall
            }
            let arrivalHorizon = UInt64(policy.arrivalGapUs) * 1_000
            if let last = state.lastArrivalNanos,
               nowNanos >= last,
               nowNanos - last >= arrivalHorizon
            {
                return state.receiveBitsPerSecond == 0 ? .networkIdle : .publisherIdle
            }
            if state.depth.frames == 0,
               let policyDrop = state.lastPolicyDropNanos,
               policyDrop >= (state.lastAdmitNanos ?? 0)
            {
                return .policyStarvation
            }
            return fallback
        }
    }

    private func onEvent(_ event: PipelineEvent) {
        let context = event.context
        let key = Key(trackId: context.trackId, mediaKind: context.mediaKind)
        lock.withLock {
            var state = states[key] ?? State()
            switch event {
            case .frameArrived:
                state.lastArrivalNanos = context.timestampNanos
            case .frameAdmitted(_, _, let depth):
                state.lastAdmitNanos = context.timestampNanos
                state.depth = depth
            case .frameDropped(_, let stage, _, _, _, _, _):
                if stage == .timeline {
                    state.lastPolicyDropNanos = context.timestampNanos
                }
            case .bufferDepthChanged(_, let depth):
                state.depth = depth
            case .bandwidthSample(_, let receive, _):
                state.receiveBitsPerSecond = receive
            case .switchProgress(_, let phase):
                state.switchPhase = phase
            default:
                return
            }
            states[key] = state
        }
    }
}
