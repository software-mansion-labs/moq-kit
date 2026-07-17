import CoreMedia

enum VideoPresentationDecision: Equatable {
    case wait(delayUs: UInt64)
    case beginStall
    case alreadyStalled
}

/// Tracks how long the last scheduled visible frame remains valid. It detects the
/// presentation boundary only; `PipelineStallAttributor` owns cause attribution.
struct VideoPresentationHorizon {
    // ~30 fps; used when no per-frame duration or interval is available.
    private static let fallbackVisibleFrameDurationUs: UInt64 = 33_333

    private(set) var lastVisibleFramePTSUs: UInt64?
    private(set) var lastVisibleFrameEndUs: UInt64?
    private(set) var hasPendingStallMarker = false
    private(set) var isStalled = false

    private var lastVisibleFrameIntervalUs: UInt64?

    @discardableResult
    mutating func recordVisibleFrame(
        sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime,
        frontFrameIntervalUs: UInt64?
    ) -> Bool {
        guard let presentationTimeUs = Self.microseconds(from: presentationTime) else {
            return false
        }

        let visibleFrameIntervalUs = lastVisibleFramePTSUs.flatMap { previousPTSUs in
            presentationTimeUs > previousPTSUs ? presentationTimeUs - previousPTSUs : nil
        }
        let durationUs =
            Self.sampleDurationUs(sampleBuffer)
            ?? Self.validDurationUs(frontFrameIntervalUs)
            ?? visibleFrameIntervalUs
            ?? lastVisibleFrameIntervalUs
            ?? Self.fallbackVisibleFrameDurationUs

        if let visibleFrameIntervalUs {
            lastVisibleFrameIntervalUs = visibleFrameIntervalUs
        }
        lastVisibleFramePTSUs = presentationTimeUs
        lastVisibleFrameEndUs = Self.addClamping(presentationTimeUs, durationUs)
        hasPendingStallMarker = false

        guard isStalled else { return false }
        isStalled = false
        return true
    }

    mutating func evaluateStallStart(at nowUs: UInt64) -> VideoPresentationDecision {
        guard !isStalled else {
            hasPendingStallMarker = false
            return .alreadyStalled
        }

        if let lastVisibleFrameEndUs, nowUs < lastVisibleFrameEndUs {
            hasPendingStallMarker = true
            return .wait(delayUs: lastVisibleFrameEndUs - nowUs)
        }

        hasPendingStallMarker = false
        isStalled = true
        return .beginStall
    }

    mutating func clearPendingStallMarker() {
        hasPendingStallMarker = false
    }

    mutating func reset() {
        lastVisibleFramePTSUs = nil
        lastVisibleFrameEndUs = nil
        hasPendingStallMarker = false
        isStalled = false
        lastVisibleFrameIntervalUs = nil
    }

    private static func sampleDurationUs(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        validDurationUs(CMSampleBufferGetDuration(sampleBuffer))
    }

    private static func validDurationUs(_ duration: CMTime) -> UInt64? {
        guard duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
            return nil
        }
        return microseconds(from: duration)
    }

    private static func validDurationUs(_ durationUs: UInt64?) -> UInt64? {
        guard let durationUs, durationUs > 0 else { return nil }
        return durationUs
    }

    private static func microseconds(from time: CMTime) -> UInt64? {
        guard time.isValid, time.isNumeric else { return nil }
        let converted = CMTimeConvertScale(
            time,
            timescale: 1_000_000,
            method: .roundHalfAwayFromZero
        )
        guard converted.isValid, converted.value >= 0 else { return nil }
        return UInt64(converted.value)
    }

    private static func addClamping(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
