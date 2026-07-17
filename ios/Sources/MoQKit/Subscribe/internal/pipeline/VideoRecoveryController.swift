import Foundation

struct VideoRecoveryAttempt: Equatable {
    let attempt: Int
    let step: RecoveryStep
    let trigger: String
}

/// Bounded recovery policy for `AVSampleBufferDisplayLayer`.
///
/// iOS owns video decoding inside AVFoundation, so recovery flushes the display renderer
/// and waits for an IDR instead of rebuilding an app-owned decoder session.
final class VideoRecoveryController {
    private let policy: RecoveryPolicy
    private let timeSource: any PipelineTimeSource
    private var recoveryTimes: [UInt64] = []

    init(
        policy: RecoveryPolicy = PipelinePolicies.recovery,
        timeSource: any PipelineTimeSource = MonotonicPipelineTimeSource()
    ) {
        self.policy = policy
        self.timeSource = timeSource
    }

    func onFailure(trigger: String) -> VideoRecoveryAttempt {
        let now = timeSource.nowNanos
        recoveryTimes.removeAll { timestamp in
            now >= timestamp && now - timestamp > policy.windowNanos
        }
        guard recoveryTimes.count < policy.maxRecoveries else {
            return VideoRecoveryAttempt(
                attempt: recoveryTimes.count + 1,
                step: .fail,
                trigger: trigger
            )
        }

        let attempt = recoveryTimes.count + 1
        recoveryTimes.append(now)
        return VideoRecoveryAttempt(attempt: attempt, step: .flush, trigger: trigger)
    }
}
