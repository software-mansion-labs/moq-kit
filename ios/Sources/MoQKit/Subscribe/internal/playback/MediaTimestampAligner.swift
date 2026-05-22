import Foundation

/// Correlates raw video timestamps with the audio playback timestamp domain.
final class MediaTimestampAligner: @unchecked Sendable {
    let audioLiveEdge: MediaLiveEdge
    let videoLiveEdge: MediaLiveEdge

    init(
        audioLiveEdge: MediaLiveEdge = MediaLiveEdge(),
        videoLiveEdge: MediaLiveEdge = MediaLiveEdge()
    ) {
        self.audioLiveEdge = audioLiveEdge
        self.videoLiveEdge = videoLiveEdge
    }

    func videoOffset(threshold: Int64) -> Int64? {
        guard let audioTime = audioLiveEdge.estimatedLivePTS(),
            let videoTime = videoLiveEdge.estimatedLivePTS()
        else { return nil }
        let result = audioTime.subtractingReportingOverflow(videoTime)
        guard !result.overflow else { return nil }
        let offset = result.partialValue
        guard Self.absoluteValue(offset, exceeds: threshold) else { return nil }
        return offset
    }

    func audioTime(videoTime: UInt64, threshold: Int64) -> UInt64 {
        guard let offset = videoOffset(threshold: threshold) else { return videoTime }
        return Self.adjustedTimestamp(videoTime, offset: offset) ?? videoTime
    }

    func videoTime(audioTime: UInt64, threshold: Int64) -> UInt64 {
        guard let offset = videoOffset(threshold: threshold) else { return audioTime }
        guard let signedTime = Self.signedTimestamp(audioTime) else { return audioTime }
        let result = signedTime.subtractingReportingOverflow(offset)
        guard !result.overflow, result.partialValue >= 0 else { return audioTime }
        return UInt64(result.partialValue)
    }

    private static func adjustedTimestamp(_ timestamp: UInt64, offset: Int64) -> UInt64? {
        guard let signedTime = signedTimestamp(timestamp) else { return nil }
        let result = signedTime.addingReportingOverflow(offset)
        guard !result.overflow, result.partialValue >= 0 else { return nil }
        return UInt64(result.partialValue)
    }

    private static func signedTimestamp(_ timestamp: UInt64) -> Int64? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return Int64(timestamp)
    }

    private static func absoluteValue(_ value: Int64, exceeds threshold: Int64) -> Bool {
        guard threshold >= 0 else { return true }
        if value == Int64.min { return true }
        return abs(value) > threshold
    }
}

extension MediaTimestampAligner: MediaFrameObserver {
    func onMediaTrackStarted(kind: MediaFrameKind) {}

    func onMediaFrame(kind: MediaFrameKind, frame: MediaFrame) {
        switch kind {
        case .audio:
            audioLiveEdge.recordTimestamp(frame.timestampUs)
        case .video:
            videoLiveEdge.recordTimestamp(frame.timestampUs)
        }
    }

    func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        switch kind {
        case .audio:
            audioLiveEdge.reset()
        case .video:
            videoLiveEdge.reset()
        }
    }
}
