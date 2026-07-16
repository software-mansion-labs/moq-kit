package com.swmansion.moqkit.subscribe

/** Media kind associated with a diagnostic pipeline event. */
enum class PipelineMediaKind { AUDIO, VIDEO }

/** Track and monotonic-clock context shared by diagnostic events. */
data class PipelineContext(
    val trackId: String,
    val mediaKind: PipelineMediaKind,
    val timestampNanos: Long,
)

/** Current occupancy of a media pipeline buffer. */
data class BufferDepth(
    val frames: Int,
    val bytes: Long,
    val durationUs: Long,
) {
    init {
        require(frames >= 0) { "frames must be non-negative" }
        require(bytes >= 0L) { "bytes must be non-negative" }
        require(durationUs >= 0L) { "durationUs must be non-negative" }
    }

    companion object {
        val Empty = BufferDepth(frames = 0, bytes = 0L, durationUs = 0L)
    }
}

/** Playback clock adjustment selected by the clock policy. */
sealed interface RetargetDecision {
    object NoOp : RetargetDecision
    data class Nudge(val rate: Double) : RetargetDecision
    data class Jump(val positionUs: Long) : RetargetDecision
}

/** Pipeline stage at which media was discarded. */
enum class DropStage {
    /** Transport discarded or skipped media before timeline processing. */
    TRANSPORT,

    /** Timeline rejected media based on freshness or discontinuity policy. */
    TIMELINE,

    /** A bounded media buffer rejected or evicted media. */
    BUFFER,

    /** Decoder admission, output, or recovery discarded media. */
    DECODER,

    /** Render scheduling or display discarded decoded media. */
    RENDERER,

    /** Publish-side frame writing discarded media. */
    WRITER,
}

/** Reason media was discarded from the pipeline. */
enum class DropReason {
    /** Transport evicted media before it could be consumed. */
    NETWORK_EVICTED,

    /** Media was skipped to remain within the live-latency budget. */
    LATENCY_BUDGET_SKIP,

    /** Media was redundant because another range covered the same content. */
    COVERED,

    /** An expected transport sequence range was never delivered. */
    MISSING_SEQUENCE,

    /** Publisher sequence or timestamps moved backward into a new epoch. */
    PUBLISHER_REWIND,

    /** Media was too old relative to the current playback position. */
    STALE_VS_PLAYBACK,

    /** Media was discarded while resetting after an excessive timestamp gap. */
    TIMESTAMP_GAP_RESET,

    /** A bounded buffer exceeded its frame, byte, or duration limit. */
    BACKLOG_OVERFLOW,

    /** Buffered media was discarded by a local pipeline reset. */
    RESET_FLUSH,

    /** Delta media arrived while the pipeline required a keyframe. */
    WAITING_FOR_KEYFRAME,

    /** Decoded or queued media was discarded while recovering the decoder. */
    DECODER_RECOVERY_FLUSH,

    /** Decoder had no input capacity when media was offered. */
    DECODER_INPUT_BACKPRESSURE,

    /** Media missed its latest useful render time. */
    LATE_RENDER,

    /** Media was discarded while switching between renditions. */
    RENDITION_SWITCH,

    /** Encoder could not accept more input without exceeding its bounds. */
    ENCODER_BACKPRESSURE,

    /** Transport writer could not accept more media without exceeding its bounds. */
    TRANSPORT_BACKPRESSURE,

    /** Media payload could not be parsed or decoded into the expected frame representation. */
    INVALID_PAYLOAD,
}

/** Origin of a playback timeline discontinuity. */
enum class DiscontinuityReason {
    /** Publisher sequence or timestamps moved backward into a new epoch. */
    PUBLISHER_REWIND,

    /** Local timestamp-gap handling or downstream recovery reset the timeline. */
    LOCAL_RESET,
}

/** Pipeline component currently preventing playback progress. */
enum class StallCause {
    /** Media arrivals stopped while transport reported no receive throughput. */
    NETWORK_IDLE,

    /** Media arrivals stopped even though the transport was not idle. */
    PUBLISHER_IDLE,

    /** Admission or freshness policy left no playable buffered media. */
    POLICY_STARVATION,

    /** Queued decoder input produced no output within the configured horizon. */
    DECODE_STALL,

    /** Decoder output was ready but did not render within the configured horizon. */
    RENDER_STALL,

    /** Playback is waiting for a pending rendition switch to become usable. */
    SWITCH_STALL,
}

/** Ordered decoder-recovery action. */
enum class RecoveryStep {
    /** Flush and restart the current decoder session. */
    FLUSH,

    /** Release the current decoder and create a replacement session. */
    REBUILD,

    /** Stop recovery and surface a terminal decoder failure. */
    FAIL,
}

/** Operation that required decoder state to be flushed. */
enum class DecoderFlushReason {
    /** Playback timeline was reset after a discontinuity. */
    TIMELINE_RESET,

    /** Rendition cutover required queued decoder state to be discarded. */
    RENDITION_SWITCH,

    /** Decoder supervisor selected a flush as its recovery action. */
    DECODER_RECOVERY,
}

/** Current phase of a video rendition switch. */
enum class SwitchPhase {
    /** One rendition is active and no switch is pending. */
    STEADY,

    /** Pending rendition is buffering until a usable keyframe is available. */
    PREPARING,

    /** Active rendition continues until playback reaches the pending keyframe. */
    CUT_IN,

    /** Decoder must flush before swapping across a large timestamp discontinuity. */
    FLUSH_SWAP,

    /** Pending rendition was abandoned and playback remains on the active rendition. */
    ABORTED,
}

/** Structured transport or pipeline closure detail. */
data class PipelineError(val code: String, val message: String)

/**
 * Detailed, non-replayed playback and publish diagnostics.
 * Every event carries a track identity and monotonic timestamp.
 */
sealed interface PipelineEvent {
    val context: PipelineContext

    data class FrameArrived(
        override val context: PipelineContext,
        val ptsUs: Long,
        val groupSequence: Long?,
        val frameIndex: Int?,
        val bytes: Int,
    ) : PipelineEvent

    data class FrameAdmitted(
        override val context: PipelineContext,
        val ptsUs: Long,
        val bufferDepth: BufferDepth,
    ) : PipelineEvent

    data class FrameDropped(
        override val context: PipelineContext,
        val stage: DropStage,
        val reason: DropReason,
        val ptsUs: Long? = null,
        val groupSequence: Long? = null,
        val count: Int = 1,
        val bytes: Long = 0L,
    ) : PipelineEvent

    data class Discontinuity(
        override val context: PipelineContext,
        val epoch: Long,
        val reason: DiscontinuityReason,
    ) : PipelineEvent

    data class BufferDepthChanged(
        override val context: PipelineContext,
        val depth: BufferDepth,
    ) : PipelineEvent

    data class DecoderInputQueued(
        override val context: PipelineContext,
        val ptsUs: Long,
    ) : PipelineEvent

    data class DecoderOutputReady(
        override val context: PipelineContext,
        val ptsUs: Long,
    ) : PipelineEvent

    data class FrameRendered(
        override val context: PipelineContext,
        val ptsUs: Long,
        val renderNanos: Long,
    ) : PipelineEvent

    data class StallStarted(
        override val context: PipelineContext,
        val cause: StallCause,
    ) : PipelineEvent

    data class StallEnded(
        override val context: PipelineContext,
        val cause: StallCause,
        val durationMillis: Long,
    ) : PipelineEvent

    data class LatencySample(
        override val context: PipelineContext,
        val currentUs: Long?,
        val targetUs: Long,
        val bufferDepth: BufferDepth,
    ) : PipelineEvent

    data class BandwidthSample(
        override val context: PipelineContext,
        val receiveBitsPerSecond: Long?,
        val sendBitsPerSecond: Long?,
    ) : PipelineEvent

    data class DecoderRecovery(
        override val context: PipelineContext,
        val attempt: Int,
        val step: RecoveryStep,
        val trigger: String,
    ) : PipelineEvent

    /** A completed decoder flush, including the state discarded by that flush. */
    data class DecoderFlushed(
        override val context: PipelineContext,
        val reason: DecoderFlushReason,
        val trigger: String,
        val droppedFrames: Int,
    ) : PipelineEvent {
        init {
            require(droppedFrames >= 0) { "droppedFrames must be non-negative" }
        }
    }

    data class SwitchProgress(
        override val context: PipelineContext,
        val phase: SwitchPhase,
    ) : PipelineEvent

    data class ClockRetarget(
        override val context: PipelineContext,
        val decision: RetargetDecision,
    ) : PipelineEvent

    data class TransportClosed(
        override val context: PipelineContext,
        val error: PipelineError?,
    ) : PipelineEvent
}
