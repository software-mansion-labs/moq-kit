package com.swmansion.moqkit.subscribe.internal.pipeline

internal enum class TimelineDropReason {
    STALE_VS_PLAYBACK,
    LATENCY_BUDGET_SKIP,
    NETWORK_EVICTED,
    COVERED,
    REWIND,
    MISSING_SEQUENCE,
}

internal enum class TimelineResetReason {
    PUBLISHER_REWIND,
    TIMESTAMP_GAP,
    DOWNSTREAM_RECOVERY,
}

internal sealed interface TimelineDecision {
    data class Admit(val frame: TimedFrame) : TimelineDecision

    data class Drop(
        val reason: TimelineDropReason,
        val frame: TimedFrame? = null,
        val groupRange: LongRange? = null,
    ) : TimelineDecision

    data class Reset(
        val reason: TimelineResetReason,
        val epoch: Long,
        val resumeFrom: TimedFrame?,
    ) : TimelineDecision

    data class End(val error: PipelineError?) : TimelineDecision
}

/**
 * Sole authority for track epoch, freshness, timestamp-gap, and latency decisions.
 * The class is synchronous and deterministic; adapters supply all clock observations.
 */
internal class TrackTimeline(
    private val policy: TimelinePolicy,
    @Suppress("unused") private val timeSource: TimeSource,
) {
    private var liveEdge: Long? = null
    private var playbackPosition: Long? = null
    private var lastTimestamp: Long? = null

    var currentEpoch: Long? = null
        private set

    var targetLatencyUs: Long = policy.targetLatencyUs
        private set

    fun onIngest(event: IngestEvent): TimelineDecision = when (event) {
        is IngestEvent.Frame -> onFrame(event)
        is IngestEvent.GroupsSkipped -> TimelineDecision.Drop(
            reason = event.reason.toTimelineDropReason(),
            groupRange = event.fromSequence..event.toSequence,
        )
        is IngestEvent.Discontinuity -> resetForEpoch(event.epoch, resumeFrom = null)
        is IngestEvent.Closed -> TimelineDecision.End(event.error)
    }

    fun onPlaybackPosition(positionUs: Long) {
        require(positionUs >= 0L) { "positionUs must be non-negative" }
        playbackPosition = positionUs
    }

    fun requestReset(reason: TimelineResetReason = TimelineResetReason.DOWNSTREAM_RECOVERY): TimelineDecision.Reset {
        lastTimestamp = null
        return TimelineDecision.Reset(
            reason = reason,
            epoch = currentEpoch ?: 0L,
            resumeFrom = null,
        )
    }

    fun liveEdgeUs(): Long? = liveEdge

    fun currentLatencyUs(): Long? {
        val edge = liveEdge ?: return null
        val playback = playbackPosition ?: return null
        return subtractClampedToZero(edge, playback)
    }

    fun setTargetLatency(us: Long) {
        require(us >= 0L) { "target latency must be non-negative" }
        targetLatencyUs = us
    }

    private fun onFrame(event: IngestEvent.Frame): TimelineDecision {
        val frame = event.frame
        val epoch = currentEpoch
        if (epoch != null && frame.epoch != epoch) {
            return resetForEpoch(frame.epoch, resumeFrom = frame)
        }
        if (epoch == null) {
            currentEpoch = frame.epoch
        }

        val previousTimestamp = lastTimestamp
        if (previousTimestamp != null && absoluteDifference(frame.timestampUs, previousTimestamp) > policy.maxGapUs) {
            lastTimestamp = frame.timestampUs
            liveEdge = frame.timestampUs
            return TimelineDecision.Reset(
                reason = TimelineResetReason.TIMESTAMP_GAP,
                epoch = frame.epoch,
                resumeFrom = frame,
            )
        }

        val playback = playbackPosition
        if (playback != null && isOlderThanFreshnessBudget(frame.timestampUs, playback)) {
            return TimelineDecision.Drop(
                reason = TimelineDropReason.STALE_VS_PLAYBACK,
                frame = frame,
            )
        }

        lastTimestamp = frame.timestampUs
        liveEdge = maxOf(liveEdge ?: frame.timestampUs, frame.timestampUs)
        return TimelineDecision.Admit(frame)
    }

    private fun resetForEpoch(epoch: Long, resumeFrom: TimedFrame?): TimelineDecision.Reset {
        require(epoch >= 0L) { "epoch must be non-negative" }
        currentEpoch = epoch
        lastTimestamp = resumeFrom?.timestampUs
        liveEdge = resumeFrom?.timestampUs
        return TimelineDecision.Reset(
            reason = TimelineResetReason.PUBLISHER_REWIND,
            epoch = epoch,
            resumeFrom = resumeFrom,
        )
    }

    private fun isOlderThanFreshnessBudget(timestampUs: Long, playbackUs: Long): Boolean {
        if (timestampUs >= playbackUs) return false
        return playbackUs - timestampUs > policy.freshnessBudgetUs
    }

    private fun subtractClampedToZero(left: Long, right: Long): Long =
        if (left <= right) 0L else left - right

    private fun absoluteDifference(left: Long, right: Long): Long =
        if (left >= right) left - right else right - left

    private fun TransportSkipReason.toTimelineDropReason(): TimelineDropReason = when (this) {
        TransportSkipReason.LATENCY_BUDGET -> TimelineDropReason.LATENCY_BUDGET_SKIP
        TransportSkipReason.EVICTED -> TimelineDropReason.NETWORK_EVICTED
        TransportSkipReason.COVERED -> TimelineDropReason.COVERED
        TransportSkipReason.REWIND -> TimelineDropReason.REWIND
        TransportSkipReason.MISSING_SEQUENCE -> TimelineDropReason.MISSING_SEQUENCE
    }
}
