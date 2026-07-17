import Foundation

/// Media kind associated with a diagnostic pipeline event.
public enum PipelineMediaKind: Sendable, Equatable, Hashable {
    case audio
    case video
}

/// Track and monotonic-clock context shared by diagnostic events.
public struct PipelineContext: Sendable, Equatable {
    public let trackId: String
    public let mediaKind: PipelineMediaKind
    public let timestampNanos: UInt64

    public init(trackId: String, mediaKind: PipelineMediaKind, timestampNanos: UInt64) {
        self.trackId = trackId
        self.mediaKind = mediaKind
        self.timestampNanos = timestampNanos
    }
}

/// Current occupancy of a media pipeline buffer.
public struct BufferDepth: Sendable, Equatable {
    public let frames: Int
    public let bytes: UInt64
    public let durationUs: UInt64

    public init(frames: Int, bytes: UInt64, durationUs: UInt64) {
        precondition(frames >= 0, "frames must be non-negative")
        self.frames = frames
        self.bytes = bytes
        self.durationUs = durationUs
    }

    public static let empty = BufferDepth(frames: 0, bytes: 0, durationUs: 0)
}

/// Playback-clock adjustment selected by the clock policy.
public enum RetargetDecision: Sendable, Equatable {
    case noOp
    case nudge(rate: Double)
    case jump(positionUs: Int64)
}

/// Pipeline stage at which media was discarded.
public enum DropStage: Sendable, Equatable {
    case transport
    case timeline
    case buffer
    case decoder
    case renderer
    case writer
}

/// Reason media was discarded from the pipeline.
public enum DropReason: Sendable, Equatable {
    case networkEvicted
    case latencyBudgetSkip
    case covered
    case missingSequence
    case publisherRewind
    case staleVsPlayback
    case timestampGapReset
    case backlogOverflow
    case resetFlush
    case waitingForKeyframe
    case decoderRecoveryFlush
    case decoderInputBackpressure
    case lateRender
    case renditionSwitch
    case encoderBackpressure
    case transportBackpressure
    case invalidPayload
}

/// Origin of a playback timeline discontinuity.
public enum DiscontinuityReason: Sendable, Equatable {
    case publisherRewind
    case localReset
}

/// Pipeline component currently preventing playback progress.
public enum StallCause: Sendable, Equatable {
    case networkIdle
    case publisherIdle
    case policyStarvation
    case decodeStall
    case renderStall
    case switchStall
}

/// Ordered media-recovery action.
public enum RecoveryStep: Sendable, Equatable {
    case flush
    case rebuild
    case fail
}

/// Operation that required decoding or display state to be flushed.
public enum DecoderFlushReason: Sendable, Equatable {
    case timelineReset
    case renditionSwitch
    case decoderRecovery
}

/// Current phase of a video rendition switch.
public enum SwitchPhase: Sendable, Equatable {
    case steady
    case preparing
    case cutIn
    case flushSwap
    case aborted
}

/// Structured transport or pipeline closure detail.
public struct PipelineError: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Detailed, non-replayed playback diagnostics.
///
/// `frameRendered` means AVFoundation accepted the sample for scheduled output. It does not
/// claim that the display panel scanned out the frame.
public enum PipelineEvent: Sendable, Equatable {
    case frameArrived(
        context: PipelineContext,
        ptsUs: Int64,
        groupSequence: UInt64?,
        frameIndex: UInt32?,
        bytes: Int
    )
    case frameAdmitted(context: PipelineContext, ptsUs: Int64, bufferDepth: BufferDepth)
    case frameDropped(
        context: PipelineContext,
        stage: DropStage,
        reason: DropReason,
        ptsUs: Int64? = nil,
        groupSequence: UInt64? = nil,
        count: Int = 1,
        bytes: UInt64 = 0
    )
    case discontinuity(
        context: PipelineContext,
        epoch: UInt64,
        reason: DiscontinuityReason
    )
    case bufferDepthChanged(context: PipelineContext, depth: BufferDepth)
    case decoderInputQueued(context: PipelineContext, ptsUs: Int64)
    case decoderOutputReady(context: PipelineContext, ptsUs: Int64)
    case frameRendered(context: PipelineContext, ptsUs: Int64, renderNanos: UInt64)
    case stallStarted(context: PipelineContext, cause: StallCause)
    case stallEnded(context: PipelineContext, cause: StallCause, durationMillis: UInt64)
    case latencySample(
        context: PipelineContext,
        currentUs: Int64?,
        targetUs: Int64,
        bufferDepth: BufferDepth
    )
    case bandwidthSample(
        context: PipelineContext,
        receiveBitsPerSecond: UInt64?,
        sendBitsPerSecond: UInt64?
    )
    case decoderRecovery(
        context: PipelineContext,
        attempt: Int,
        step: RecoveryStep,
        trigger: String
    )
    case decoderFlushed(
        context: PipelineContext,
        reason: DecoderFlushReason,
        trigger: String,
        droppedFrames: Int
    )
    case switchProgress(context: PipelineContext, phase: SwitchPhase)
    case clockRetarget(context: PipelineContext, decision: RetargetDecision)
    case transportClosed(context: PipelineContext, error: PipelineError?)

    public var context: PipelineContext {
        switch self {
        case .frameArrived(let context, _, _, _, _),
             .frameAdmitted(let context, _, _),
             .frameDropped(let context, _, _, _, _, _, _),
             .discontinuity(let context, _, _),
             .bufferDepthChanged(let context, _),
             .decoderInputQueued(let context, _),
             .decoderOutputReady(let context, _),
             .frameRendered(let context, _, _),
             .stallStarted(let context, _),
             .stallEnded(let context, _, _),
             .latencySample(let context, _, _, _),
             .bandwidthSample(let context, _, _),
             .decoderRecovery(let context, _, _, _),
             .decoderFlushed(let context, _, _, _),
             .switchProgress(let context, _),
             .clockRetarget(let context, _),
             .transportClosed(let context, _):
            return context
        }
    }
}
