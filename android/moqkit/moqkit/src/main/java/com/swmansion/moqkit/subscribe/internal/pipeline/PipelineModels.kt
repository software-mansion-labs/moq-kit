package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame

internal fun interface TimeSource {
    fun nanoTime(): Long
}

internal object MonotonicTimeSource : TimeSource {
    override fun nanoTime(): Long = System.nanoTime()
}

internal data class TimedFrame(
    val mediaFrame: MediaFrame,
    val durationUs: Long? = null,
    val groupSequence: Long? = null,
    val frameIndex: Int? = null,
    val epoch: Long = 0L,
) {
    init {
        require(durationUs == null || durationUs >= 0L) { "durationUs must be non-negative" }
        require(groupSequence == null || groupSequence >= 0L) { "groupSequence must be non-negative" }
        require(frameIndex == null || frameIndex >= 0) { "frameIndex must be non-negative" }
        require(epoch >= 0L) { "epoch must be non-negative" }
    }

    val timestampUs: Long get() = mediaFrame.timestampUs
    val keyframe: Boolean get() = mediaFrame.keyframe
    val sizeBytes: Int get() = mediaFrame.payload.size
}

internal enum class TransportSkipReason {
    LATENCY_BUDGET,
    EVICTED,
    COVERED,
    REWIND,
    MISSING_SEQUENCE,
}

internal data class PipelineError(
    val code: String,
    val message: String,
)

internal sealed interface IngestEvent {
    data class Frame(
        val frame: TimedFrame,
        val arrivalNanos: Long,
    ) : IngestEvent

    data class GroupsSkipped(
        val fromSequence: Long,
        val toSequence: Long,
        val reason: TransportSkipReason,
    ) : IngestEvent

    data class Discontinuity(val epoch: Long) : IngestEvent

    data class Closed(val error: PipelineError?) : IngestEvent
}

internal enum class PipelineMediaKind { AUDIO, VIDEO }

internal data class PipelineContext(
    val trackId: String,
    val mediaKind: PipelineMediaKind,
    val timestampNanos: Long,
)

internal data class BufferDepth(
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

internal sealed interface RetargetDecision {
    object NoOp : RetargetDecision
    data class Nudge(val rate: Double) : RetargetDecision
    data class Jump(val positionUs: Long) : RetargetDecision
}

internal enum class DropStage {
    TRANSPORT,
    TIMELINE,
    BUFFER,
    DECODER,
    RENDERER,
    WRITER,
}

internal enum class DropReason {
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
}

internal enum class DiscontinuityReason { PUBLISHER_REWIND, LOCAL_RESET }

internal enum class StallCause {
    NETWORK_IDLE,
    PUBLISHER_IDLE,
    POLICY_STARVATION,
    DECODE_STALL,
    RENDER_STALL,
    SWITCH_STALL,
}

internal enum class RecoveryStep { FLUSH, REBUILD, FAIL }

internal enum class SwitchPhase { STEADY, PREPARING, CUT_IN, FLUSH_SWAP, ABORTED }

internal sealed interface PipelineEvent {
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
