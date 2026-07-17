import Foundation

enum AdmissionRejectReason: Equatable {
    case waitingForKeyframe
    case frameTooLarge
    case oldEpoch
    case unexpectedEpoch
    case duplicate
}

enum AdmissionEffect: Equatable {
    case admitted
    case rejected(reason: AdmissionRejectReason)
    case evictedGop(count: Int, bytes: UInt64)
}

/// The single bounded compressed-frame queue before video decode/display processing.
///
/// The owner serializes access. This type owns capacity admission, decode ordering,
/// whole-GOP eviction, duplicate rejection, and keyframe gating after reset.
final class FrameBuffer<Payload> {
    private let policy: AdmissionPolicy
    private var frames: [PipelineFrame<Payload>] = []
    private var byteCount: UInt64 = 0
    private var keyframeAccepted: Bool

    private(set) var currentEpoch: UInt64?

    init(policy: AdmissionPolicy = PipelinePolicies.admission) {
        precondition(policy.maxBytes > 0)
        precondition(policy.maxFrames > 0)
        precondition(policy.maxDurationUs > 0)
        self.policy = policy
        self.keyframeAccepted = !policy.requireKeyframeAfterReset
    }

    func offer(_ frame: PipelineFrame<Payload>) -> [AdmissionEffect] {
        if let reason = rejectionReason(for: frame) {
            return [.rejected(reason: reason)]
        }
        if currentEpoch == nil {
            currentEpoch = frame.epoch
        }

        var effects: [AdmissionEffect] = []
        if frame.keyframe, !keyframeAccepted, !frames.isEmpty {
            effects.append(evictAll())
        }
        if frame.keyframe {
            keyframeAccepted = true
        }
        let index = frames.firstIndex { existing in
            if existing.timestampUs != frame.timestampUs {
                return existing.timestampUs > frame.timestampUs
            }
            return (existing.frameIndex ?? .max) > (frame.frameIndex ?? .max)
        } ?? frames.endIndex
        frames.insert(frame, at: index)
        byteCount += UInt64(frame.sizeBytes)
        effects.append(.admitted)

        while isOverflowing, !frames.isEmpty {
            effects.append(evictOldestGop())
        }
        return effects
    }

    func rejectionReason(for frame: PipelineFrame<Payload>) -> AdmissionRejectReason? {
        if UInt64(frame.sizeBytes) > policy.maxBytes { return .frameTooLarge }
        if let currentEpoch, frame.epoch < currentEpoch { return .oldEpoch }
        if let currentEpoch, frame.epoch > currentEpoch { return .unexpectedEpoch }
        if !keyframeAccepted, !frame.keyframe { return .waitingForKeyframe }
        if frames.contains(where: { existing in
            guard existing.epoch == frame.epoch, existing.timestampUs == frame.timestampUs else {
                return false
            }
            if let existingGroup = existing.groupSequence,
               let newGroup = frame.groupSequence
            {
                return existingGroup == newGroup && existing.frameIndex == frame.frameIndex
            }
            return existing.keyframe == frame.keyframe
        }) {
            return .duplicate
        }
        return nil
    }

    func reset(epoch: UInt64) -> Int {
        let count = frames.count
        frames.removeAll(keepingCapacity: true)
        byteCount = 0
        currentEpoch = epoch
        keyframeAccepted = !policy.requireKeyframeAfterReset
        return count
    }

    func peekFront() -> PipelineFrame<Payload>? {
        frames.first
    }

    func first(where predicate: (PipelineFrame<Payload>) -> Bool) -> PipelineFrame<Payload>? {
        frames.first(where: predicate)
    }

    func contains(where predicate: (PipelineFrame<Payload>) -> Bool) -> Bool {
        frames.contains(where: predicate)
    }

    func removeFront() -> PipelineFrame<Payload>? {
        guard !frames.isEmpty else { return nil }
        let removed = frames.removeFirst()
        byteCount -= UInt64(removed.sizeBytes)
        return removed
    }

    func depth() -> BufferDepth {
        BufferDepth(
            frames: frames.count,
            bytes: byteCount,
            durationUs: UInt64(max(0, bufferedDurationUs))
        )
    }

    var frontFrameIntervalUs: Int64? {
        guard frames.count >= 2 else { return nil }
        return max(0, frames[1].timestampUs - frames[0].timestampUs)
    }

    private var bufferedDurationUs: Int64 {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return max(0, last.timestampUs - first.timestampUs)
    }

    private var isOverflowing: Bool {
        byteCount > policy.maxBytes
            || frames.count > policy.maxFrames
            || bufferedDurationUs > policy.maxDurationUs
    }

    private func evictOldestGop() -> AdmissionEffect {
        let first = frames[0]
        let count: Int
        if !policy.evictWholeGops {
            count = 1
        } else if let group = first.groupSequence {
            count = max(1, frames.prefix { $0.groupSequence == group }.count)
        } else if let nextKeyframe = frames.dropFirst().firstIndex(where: \.keyframe) {
            count = nextKeyframe
        } else {
            count = frames.count
        }

        var bytes: UInt64 = 0
        for _ in 0..<count {
            bytes += UInt64(frames.removeFirst().sizeBytes)
        }
        byteCount -= bytes
        if policy.requireKeyframeAfterReset {
            keyframeAccepted = frames.first?.keyframe == true
        }
        return .evictedGop(count: count, bytes: bytes)
    }

    private func evictAll() -> AdmissionEffect {
        let effect = AdmissionEffect.evictedGop(count: frames.count, bytes: byteCount)
        frames.removeAll(keepingCapacity: true)
        byteCount = 0
        return effect
    }
}
