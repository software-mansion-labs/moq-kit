package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame

internal typealias BufferDepth = com.swmansion.moqkit.subscribe.BufferDepth
internal typealias DiscontinuityReason = com.swmansion.moqkit.subscribe.DiscontinuityReason
internal typealias DropReason = com.swmansion.moqkit.subscribe.DropReason
internal typealias DropStage = com.swmansion.moqkit.subscribe.DropStage
internal typealias PipelineContext = com.swmansion.moqkit.subscribe.PipelineContext
internal typealias PipelineError = com.swmansion.moqkit.subscribe.PipelineError
internal typealias PipelineMediaKind = com.swmansion.moqkit.subscribe.PipelineMediaKind
internal typealias RecoveryStep = com.swmansion.moqkit.subscribe.RecoveryStep
internal typealias StallCause = com.swmansion.moqkit.subscribe.StallCause
internal typealias SwitchPhase = com.swmansion.moqkit.subscribe.SwitchPhase

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
    /** Groups skipped to keep playback within its live-latency budget. */
    LATENCY_BUDGET,

    /** Groups removed by transport retention or capacity limits before they were consumed. */
    EVICTED,

    /** Groups superseded by another transport range that covers the same media. */
    COVERED,

    /** Groups skipped because the publisher sequence moved backward. */
    REWIND,

    /** Groups expected from the sequence but never delivered by the transport. */
    MISSING_SEQUENCE,
}

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
