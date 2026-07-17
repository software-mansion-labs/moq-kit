import Foundation

struct AudioRecoveryAttempt: Equatable {
    let attempt: Int
    let step: RecoveryStep
    let trigger: String
}

/// Bounded AVAudioConverter recovery. Converter work is synchronous on iOS, so recovery
/// replaces the converter rather than carrying Android's asynchronous decoder workarounds.
final class AudioRecoveryController {
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

    func onFailure(trigger: String) -> AudioRecoveryAttempt {
        let now = timeSource.nowNanos
        recoveryTimes.removeAll { timestamp in
            now >= timestamp && now - timestamp > policy.windowNanos
        }
        guard recoveryTimes.count < policy.maxRecoveries else {
            return AudioRecoveryAttempt(
                attempt: recoveryTimes.count + 1,
                step: .fail,
                trigger: trigger
            )
        }
        recoveryTimes.append(now)
        return AudioRecoveryAttempt(
            attempt: recoveryTimes.count,
            step: .rebuild,
            trigger: trigger
        )
    }
}
