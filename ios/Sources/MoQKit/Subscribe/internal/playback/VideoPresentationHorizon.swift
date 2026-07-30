import CoreMedia

enum VideoPresentationDecision: Equatable {
    case buffering
    case wait(delayUs: UInt64)
    case beginStall
    case alreadyStalled
}

enum VideoSubmissionDecision: Equatable {
    case ignored
    case horizonExtended(endUs: UInt64)
    case stallEnded(endUs: UInt64)
}

/// Tracks the furthest presentation end submitted to AVFoundation. It detects the
/// presentation boundary only; `PipelineStallAttributor` owns cause attribution.
struct VideoPresentationHorizon {
    // ~30 fps; used when no per-frame duration or interval is available.
    private static let fallbackFrameDurationUs: UInt64 = 33_333

    private(set) var latestSubmittedPTSUs: UInt64?
    private(set) var submittedHorizonEndUs: UInt64?
    private(set) var isStalled = false

    private var latestSubmittedIntervalUs: UInt64?

    @discardableResult
    mutating func recordSubmittedSample(
        sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime,
        frontFrameIntervalUs: UInt64?,
        playheadUs: UInt64
    ) -> VideoSubmissionDecision {
        guard let presentationTimeUs = Self.microseconds(from: presentationTime) else {
            return .ignored
        }

        let observedIntervalUs = latestSubmittedPTSUs.flatMap { previousPTSUs in
            presentationTimeUs > previousPTSUs ? presentationTimeUs - previousPTSUs : nil
        }
        let durationUs =
            Self.sampleDurationUs(sampleBuffer)
            ?? Self.validDurationUs(frontFrameIntervalUs)
            ?? observedIntervalUs
            ?? latestSubmittedIntervalUs
            ?? Self.fallbackFrameDurationUs

        if let observedIntervalUs {
            latestSubmittedIntervalUs = observedIntervalUs
        }
        if let latestSubmittedPTSUs {
            if presentationTimeUs > latestSubmittedPTSUs {
                self.latestSubmittedPTSUs = presentationTimeUs
            }
        } else {
            latestSubmittedPTSUs = presentationTimeUs
        }

        let candidateEndUs = Self.addClamping(presentationTimeUs, durationUs)
        guard candidateEndUs > (submittedHorizonEndUs ?? 0) else {
            return .ignored
        }
        submittedHorizonEndUs = candidateEndUs

        guard isStalled, candidateEndUs > playheadUs else {
            return .horizonExtended(endUs: candidateEndUs)
        }
        isStalled = false
        return .stallEnded(endUs: candidateEndUs)
    }

    mutating func evaluateStallStart(at playheadUs: UInt64) -> VideoPresentationDecision {
        guard !isStalled else {
            return .alreadyStalled
        }
        guard let submittedHorizonEndUs else {
            return .buffering
        }
        guard playheadUs < submittedHorizonEndUs else {
            isStalled = true
            return .beginStall
        }
        return .wait(delayUs: submittedHorizonEndUs - playheadUs)
    }

    /// Invalidates AVFoundation-owned presentation coverage while preserving an
    /// already-active public stall until replacement coverage is submitted.
    mutating func resetCoverage() {
        latestSubmittedPTSUs = nil
        submittedHorizonEndUs = nil
        latestSubmittedIntervalUs = nil
    }

    /// Clears all presentation and stall state during renderer teardown.
    mutating func reset() {
        self = VideoPresentationHorizon()
    }

    static func conservativeWallDelayUs(
        mediaDelayUs: UInt64,
        maxClockRate: Double
    ) -> UInt64 {
        guard mediaDelayUs > 0 else { return 0 }
        guard maxClockRate.isFinite, maxClockRate > 1 else { return mediaDelayUs }

        let scaledDelay = (Double(mediaDelayUs) / maxClockRate).rounded(.down)
        guard scaledDelay >= 1 else { return 1 }
        guard scaledDelay < Double(UInt64.max) else { return mediaDelayUs }
        return UInt64(scaledDelay)
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
