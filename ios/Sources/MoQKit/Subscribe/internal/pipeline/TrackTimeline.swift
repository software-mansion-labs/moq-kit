import Foundation

enum TimelineDropReason: Equatable {
    case staleVsPlayback
}

enum TimelineResetReason: Equatable {
    case publisherRewind
    case timestampGap
    case downstreamRecovery
}

enum TimelineDecision<Payload> {
    case admit(PipelineFrame<Payload>)
    case drop(reason: TimelineDropReason, frame: PipelineFrame<Payload>)
    case reset(
        reason: TimelineResetReason,
        epoch: UInt64,
        resumeFrom: PipelineFrame<Payload>?,
        gapUs: UInt64?
    )
}

/// Sole authority for one track's epoch, live edge, freshness, and timestamp-gap resets.
final class TrackTimeline: @unchecked Sendable {
    private let lock = UnfairLock()
    private let policy: TimelinePolicy
    private let timeSource: any PipelineTimeSource

    private var liveEdgeOffsetUs: Int64?
    private var playbackPositionUs: Int64?
    private var lastTimestampUs: Int64?
    private var epoch: UInt64?
    private var latencyTargetUs: Int64

    init(
        policy: TimelinePolicy = PipelinePolicies.timeline,
        timeSource: any PipelineTimeSource = MonotonicPipelineTimeSource()
    ) {
        self.policy = policy
        self.timeSource = timeSource
        self.latencyTargetUs = policy.targetLatencyUs
    }

    func onFrame<Payload>(
        _ frame: PipelineFrame<Payload>,
        arrivalNanos: UInt64? = nil
    ) -> TimelineDecision<Payload> {
        lock.withLock {
            let arrival = arrivalNanos ?? timeSource.nowNanos

            if let epoch, frame.epoch != epoch {
                self.epoch = frame.epoch
                lastTimestampUs = frame.timestampUs
                playbackPositionUs = nil
                resetLiveEdge(timestampUs: frame.timestampUs, arrivalNanos: arrival)
                return .reset(
                    reason: .publisherRewind,
                    epoch: frame.epoch,
                    resumeFrom: frame,
                    gapUs: nil
                )
            }
            if epoch == nil {
                epoch = frame.epoch
            }

            if let previous = lastTimestampUs {
                let gap = Self.absoluteDifference(previous, frame.timestampUs)
                if gap > UInt64(policy.maxGapUs) {
                    lastTimestampUs = frame.timestampUs
                    playbackPositionUs = nil
                    resetLiveEdge(timestampUs: frame.timestampUs, arrivalNanos: arrival)
                    return .reset(
                        reason: .timestampGap,
                        epoch: frame.epoch,
                        resumeFrom: frame,
                        gapUs: gap
                    )
                }
            }

            if let playbackPositionUs,
               frame.timestampUs < playbackPositionUs,
               playbackPositionUs - frame.timestampUs > policy.freshnessBudgetUs
            {
                return .drop(reason: .staleVsPlayback, frame: frame)
            }

            lastTimestampUs = frame.timestampUs
            recordLiveEdge(timestampUs: frame.timestampUs, arrivalNanos: arrival)
            return .admit(frame)
        }
    }

    func onPlaybackPosition(_ positionUs: Int64) {
        precondition(positionUs >= 0, "positionUs must be non-negative")
        lock.withLock {
            playbackPositionUs = positionUs
        }
    }

    func requestReset<Payload>(
        reason: TimelineResetReason = .downstreamRecovery
    ) -> TimelineDecision<Payload> {
        lock.withLock {
            lastTimestampUs = nil
            liveEdgeOffsetUs = nil
            playbackPositionUs = nil
            return .reset(
                reason: reason,
                epoch: epoch ?? 0,
                resumeFrom: nil,
                gapUs: nil
            )
        }
    }

    var currentEpoch: UInt64? {
        lock.withLock { epoch }
    }

    var targetLatencyUs: Int64 {
        lock.withLock { latencyTargetUs }
    }

    func setTargetLatencyUs(_ targetLatencyUs: Int64) {
        precondition(targetLatencyUs >= 0, "target latency must be non-negative")
        lock.withLock {
            latencyTargetUs = targetLatencyUs
        }
    }

    func liveEdgeUs() -> Int64? {
        lock.withLock {
            guard let liveEdgeOffsetUs else { return nil }
            let nowUs = Int64(clamping: timeSource.nowNanos / 1_000)
            let result = nowUs.addingReportingOverflow(liveEdgeOffsetUs)
            return result.overflow ? nil : result.partialValue
        }
    }

    func targetPlaybackUs() -> Int64? {
        guard let liveEdge = liveEdgeUs() else { return nil }
        return max(0, liveEdge - targetLatencyUs)
    }

    func currentLatencyUs() -> Int64? {
        lock.withLock {
            guard let liveEdgeOffsetUs, let playbackPositionUs else { return nil }
            let nowUs = Int64(clamping: timeSource.nowNanos / 1_000)
            let edgeResult = nowUs.addingReportingOverflow(liveEdgeOffsetUs)
            guard !edgeResult.overflow else { return nil }
            return max(0, edgeResult.partialValue - playbackPositionUs)
        }
    }

    private func recordLiveEdge(timestampUs: Int64, arrivalNanos: UInt64) {
        let arrivalUs = Int64(clamping: arrivalNanos / 1_000)
        let result = timestampUs.subtractingReportingOverflow(arrivalUs)
        guard !result.overflow else { return }
        liveEdgeOffsetUs = max(liveEdgeOffsetUs ?? Int64.min, result.partialValue)
    }

    private func resetLiveEdge(timestampUs: Int64, arrivalNanos: UInt64) {
        liveEdgeOffsetUs = nil
        recordLiveEdge(timestampUs: timestampUs, arrivalNanos: arrivalNanos)
    }

    private static func absoluteDifference(_ left: Int64, _ right: Int64) -> UInt64 {
        if left >= right {
            return UInt64(left) - UInt64(right)
        }
        return UInt64(right) - UInt64(left)
    }
}
