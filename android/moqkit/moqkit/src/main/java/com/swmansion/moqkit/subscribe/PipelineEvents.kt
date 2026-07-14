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

enum class DropStage { TRANSPORT, TIMELINE, BUFFER, DECODER, RENDERER, WRITER }

enum class DropReason {
    NETWORK_EVICTED,
    LATENCY_BUDGET_SKIP,
    COVERED,
    MISSING_SEQUENCE,
    PUBLISHER_REWIND,
    STALE_VS_PLAYBACK,
    TIMESTAMP_GAP_RESET,
    BACKLOG_OVERFLOW,
    RESET_FLUSH,
    WAITING_FOR_KEYFRAME,
    DECODER_RECOVERY_FLUSH,
    DECODER_INPUT_BACKPRESSURE,
    LATE_RENDER,
    RENDITION_SWITCH,
    ENCODER_BACKPRESSURE,
    TRANSPORT_BACKPRESSURE,
    INVALID_PAYLOAD,
}

enum class DiscontinuityReason { PUBLISHER_REWIND, LOCAL_RESET }

enum class StallCause {
    NETWORK_IDLE,
    PUBLISHER_IDLE,
    POLICY_STARVATION,
    DECODE_STALL,
    RENDER_STALL,
    SWITCH_STALL,
}

enum class RecoveryStep { FLUSH, REBUILD, FAIL }

enum class DecoderFlushReason { TIMELINE_RESET, RENDITION_SWITCH, DECODER_RECOVERY }

enum class SwitchPhase { STEADY, PREPARING, CUT_IN, FLUSH_SWAP, ABORTED }

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
