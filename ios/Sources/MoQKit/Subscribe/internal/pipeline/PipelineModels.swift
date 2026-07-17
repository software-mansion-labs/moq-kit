import Foundation

protocol PipelineTimeSource: Sendable {
    var nowNanos: UInt64 { get }
}

struct MonotonicPipelineTimeSource: PipelineTimeSource {
    var nowNanos: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

struct PipelineFrame<Payload> {
    let payload: Payload
    let timestampUs: Int64
    let keyframe: Bool
    let sizeBytes: Int
    let durationUs: Int64?
    let groupSequence: UInt64?
    let frameIndex: UInt32?
    let epoch: UInt64

    init(
        payload: Payload,
        timestampUs: Int64,
        keyframe: Bool,
        sizeBytes: Int,
        durationUs: Int64? = nil,
        groupSequence: UInt64? = nil,
        frameIndex: UInt32? = nil,
        epoch: UInt64 = 0
    ) {
        precondition(timestampUs >= 0, "timestampUs must be non-negative")
        precondition(sizeBytes >= 0, "sizeBytes must be non-negative")
        precondition(durationUs.map { $0 >= 0 } ?? true, "durationUs must be non-negative")
        self.payload = payload
        self.timestampUs = timestampUs
        self.keyframe = keyframe
        self.sizeBytes = sizeBytes
        self.durationUs = durationUs
        self.groupSequence = groupSequence
        self.frameIndex = frameIndex
        self.epoch = epoch
    }
}

extension PipelineMediaKind {
    init(_ kind: MediaFrameKind) {
        switch kind {
        case .audio: self = .audio
        case .video: self = .video
        }
    }

    var mediaFrameKind: MediaFrameKind {
        switch self {
        case .audio: return .audio
        case .video: return .video
        }
    }
}

struct PipelineContextFactory: Sendable {
    let trackId: String
    let mediaKind: PipelineMediaKind
    let timeSource: any PipelineTimeSource

    init(
        trackId: String,
        mediaKind: PipelineMediaKind,
        timeSource: any PipelineTimeSource = MonotonicPipelineTimeSource()
    ) {
        self.trackId = trackId
        self.mediaKind = mediaKind
        self.timeSource = timeSource
    }

    func make() -> PipelineContext {
        PipelineContext(
            trackId: trackId,
            mediaKind: mediaKind,
            timestampNanos: timeSource.nowNanos
        )
    }
}
