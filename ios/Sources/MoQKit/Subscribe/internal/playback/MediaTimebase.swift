import CoreMedia
import Foundation

/// Tracks the estimated live edge for one media stream from compressed-frame arrivals.
final class MediaLiveEdgeOffset: @unchecked Sendable {
    private let lock = NSLock()
    private let wallClockUsProvider: @Sendable () -> Int64
    private var maxOffsetUs: Int64?

    convenience init() {
        let hostClock = CMClockGetHostTimeClock()
        self.init {
            let hostTime = CMClockGetTime(hostClock)
            let wallTime = CMTimeConvertScale(
                hostTime,
                timescale: 1_000_000,
                method: .roundHalfAwayFromZero
            )
            return wallTime.value
        }
    }

    init(wallClockUsProvider: @escaping @Sendable () -> Int64) {
        self.wallClockUsProvider = wallClockUsProvider
    }

    func recordTimestamp(_ timestampUs: UInt64) {
        guard let timestamp = Self.signedTimestampUs(timestampUs) else { return }
        let result = timestamp.subtractingReportingOverflow(wallClockUsProvider())
        guard !result.overflow else { return }
        let offset = result.partialValue

        lock.lock()
        maxOffsetUs = max(maxOffsetUs ?? Int64.min, offset)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        maxOffsetUs = nil
        lock.unlock()
    }

    var estimatedLivePtsUs: Int64? {
        lock.lock()
        let offset = maxOffsetUs
        lock.unlock()

        guard let offset else { return nil }
        let result = wallClockUsProvider().addingReportingOverflow(offset)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    private static func signedTimestampUs(_ timestampUs: UInt64) -> Int64? {
        guard timestampUs <= UInt64(Int64.max) else { return nil }
        return Int64(timestampUs)
    }
}

/// Shared playback clock that reads media live-edge estimators for synchronization.
final class MediaTimebase: @unchecked Sendable {
    struct VideoPtsCorrection: Equatable {
        let offsetUs: Int64
        let correctedTimestampUs: UInt64
    }

    let audioLiveEdge: MediaLiveEdgeOffset
    let videoLiveEdge: MediaLiveEdgeOffset
    let cmTimebase: CMTimebase

    convenience init() throws {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard let tb else {
            throw SessionError.invalidConfiguration("Failed to create CMTimebase")
        }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 0)

        self.init(
            cmTimebase: tb,
            audioLiveEdge: MediaLiveEdgeOffset(),
            videoLiveEdge: MediaLiveEdgeOffset()
        )
    }

    init(
        cmTimebase: CMTimebase,
        audioLiveEdge: MediaLiveEdgeOffset,
        videoLiveEdge: MediaLiveEdgeOffset
    ) {
        self.cmTimebase = cmTimebase
        self.audioLiveEdge = audioLiveEdge
        self.videoLiveEdge = videoLiveEdge
    }

    func setTimeUs(_ timestampUs: UInt64) {
        CMTimebaseSetTime(
            cmTimebase,
            time: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000)
        )
    }

    func setRate(_ rate: Double) {
        CMTimebaseSetRate(cmTimebase, rate: rate)
    }

    var currentTimeUs: UInt64 {
        let time = CMTimebaseGetTime(cmTimebase)
        return UInt64(max(0, time.seconds * 1_000_000))
    }

    func estimatedLivePtsDifferenceUs() -> Int64? {
        guard let audioPts = audioLiveEdge.estimatedLivePtsUs,
            let videoPts = videoLiveEdge.estimatedLivePtsUs
        else { return nil }
        let result = audioPts.subtractingReportingOverflow(videoPts)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    func videoPtsCorrectionUs(thresholdUs: Int64) -> Int64? {
        guard let difference = estimatedLivePtsDifferenceUs(),
            Self.absoluteValue(difference, exceeds: thresholdUs)
        else {
            return nil
        }
        return difference
    }

    func videoPtsCorrection(
        forSourceTimestampUs sourceTimestampUs: UInt64,
        thresholdUs: Int64
    ) -> VideoPtsCorrection? {
        guard let correctionUs = videoPtsCorrectionUs(thresholdUs: thresholdUs),
            let correctedTimestampUs = Self.correctedTimestampUs(
                sourceTimestampUs: sourceTimestampUs,
                correctionUs: correctionUs)
        else {
            return nil
        }

        return VideoPtsCorrection(
            offsetUs: correctionUs,
            correctedTimestampUs: correctedTimestampUs)
    }

    func estimatedAudioLivePtsUs() -> Int64? {
        audioLiveEdge.estimatedLivePtsUs
    }

    func estimatedVideoLivePtsUs() -> Int64? {
        videoLiveEdge.estimatedLivePtsUs
    }

    func audioLatencyMs() -> Double? {
        latencyMs(forLivePtsUs: audioLiveEdge.estimatedLivePtsUs)
    }

    func videoLatencyMs(thresholdUs: Int64) -> Double? {
        guard let videoLivePts = videoLiveEdge.estimatedLivePtsUs else { return nil }
        let correction = videoPtsCorrectionUs(thresholdUs: thresholdUs) ?? 0
        let correctedResult = videoLivePts.addingReportingOverflow(correction)
        guard !correctedResult.overflow else { return nil }
        return latencyMs(forLivePtsUs: correctedResult.partialValue)
    }

    private func latencyMs(forLivePtsUs livePtsUs: Int64?) -> Double? {
        guard let livePtsUs else { return nil }
        guard currentTimeUs <= UInt64(Int64.max) else { return nil }
        let current = Int64(currentTimeUs)
        let result = livePtsUs.subtractingReportingOverflow(current)
        guard !result.overflow else { return nil }
        return Double(max(0, result.partialValue)) / 1_000.0
    }

    private static func correctedTimestampUs(
        sourceTimestampUs: UInt64,
        correctionUs: Int64
    ) -> UInt64? {
        guard let sourceTimestamp = signedTimestampUs(sourceTimestampUs) else { return nil }
        let correctedResult = sourceTimestamp.addingReportingOverflow(correctionUs)
        guard !correctedResult.overflow else { return nil }
        let corrected = correctedResult.partialValue
        guard corrected >= 0 else { return nil }
        return UInt64(corrected)
    }

    private static func signedTimestampUs(_ timestampUs: UInt64) -> Int64? {
        guard timestampUs <= UInt64(Int64.max) else { return nil }
        return Int64(timestampUs)
    }

    private static func absoluteValue(_ value: Int64, exceeds threshold: Int64) -> Bool {
        guard threshold >= 0 else { return true }
        if value == Int64.min { return true }
        return abs(value) > threshold
    }
}
