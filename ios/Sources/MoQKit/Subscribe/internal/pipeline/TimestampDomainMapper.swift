import Foundation

/// Maps timestamps between audio and video domains without owning either timeline.
final class TimestampDomainMapper: @unchecked Sendable {
    private let lock = UnfairLock()
    private var audioTimeline: TrackTimeline?
    private var videoTimeline: TrackTimeline?

    init(
        audioTimeline: TrackTimeline?,
        videoTimeline: TrackTimeline?
    ) {
        self.audioTimeline = audioTimeline
        self.videoTimeline = videoTimeline
    }

    func setAudioTimeline(_ timeline: TrackTimeline?) {
        lock.withLock { audioTimeline = timeline }
    }

    func setVideoTimeline(_ timeline: TrackTimeline?) {
        lock.withLock { videoTimeline = timeline }
    }

    func videoOffsetUs(thresholdUs: Int64) -> Int64? {
        precondition(thresholdUs >= 0)
        let timelines = lock.withLock { (audioTimeline, videoTimeline) }
        guard let audio = timelines.0?.liveEdgeUs(),
              let video = timelines.1?.liveEdgeUs()
        else { return nil }
        let result = audio.subtractingReportingOverflow(video)
        guard !result.overflow else { return nil }
        let offset = result.partialValue
        return Self.absoluteValue(offset, exceeds: thresholdUs) ? offset : nil
    }

    func audioTimeUs(videoTimeUs: UInt64, thresholdUs: Int64) -> UInt64 {
        guard let offset = videoOffsetUs(thresholdUs: thresholdUs),
              videoTimeUs <= UInt64(Int64.max)
        else { return videoTimeUs }
        let result = Int64(videoTimeUs).addingReportingOverflow(offset)
        guard !result.overflow, result.partialValue >= 0 else { return videoTimeUs }
        return UInt64(result.partialValue)
    }

    func videoTimeUs(audioTimeUs: UInt64, thresholdUs: Int64) -> UInt64 {
        guard let offset = videoOffsetUs(thresholdUs: thresholdUs),
              audioTimeUs <= UInt64(Int64.max)
        else { return audioTimeUs }
        let result = Int64(audioTimeUs).subtractingReportingOverflow(offset)
        guard !result.overflow, result.partialValue >= 0 else { return audioTimeUs }
        return UInt64(result.partialValue)
    }

    private static func absoluteValue(_ value: Int64, exceeds threshold: Int64) -> Bool {
        value == .min || abs(value) > threshold
    }
}
