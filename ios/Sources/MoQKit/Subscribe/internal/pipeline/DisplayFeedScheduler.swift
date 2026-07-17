import Foundation

enum DisplayFeedDecision: Equatable {
    case visible
    case decodeOnly
    case hold(recheckAfterUs: UInt64)
}

/// AVFoundation feed policy. Late/dependency frames are still enqueued with
/// `DoNotDisplay` so VideoToolbox can retain decode dependencies.
struct DisplayFeedScheduler: Sendable {
    let policy: RenderPolicy

    init(policy: RenderPolicy = PipelinePolicies.render) {
        self.policy = policy
    }

    func decision(
        framePtsUs: UInt64,
        playheadUs: UInt64,
        isPlaybackCandidate: Bool
    ) -> DisplayFeedDecision {
        guard isPlaybackCandidate else { return .decodeOnly }

        if framePtsUs < playheadUs {
            let lateness = playheadUs - framePtsUs
            return lateness > UInt64(policy.lateDropThresholdUs) ? .decodeOnly : .visible
        }

        let ahead = framePtsUs - playheadUs
        if ahead > UInt64(policy.maxAheadUs) {
            return .hold(recheckAfterUs: ahead - UInt64(policy.maxAheadUs))
        }
        return .visible
    }
}
