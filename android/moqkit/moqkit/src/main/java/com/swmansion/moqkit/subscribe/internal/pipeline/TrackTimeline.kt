package com.swmansion.moqkit.subscribe.internal.pipeline

internal enum class TimelineDropReason {
    /** Frame is older than the current playback position by more than the freshness budget. */
    STALE_VS_PLAYBACK,

    /** Transport groups were skipped to keep playback within its live-latency budget. */
    LATENCY_BUDGET_SKIP,

    /** Transport groups were evicted before the timeline could consume them. */
    NETWORK_EVICTED,

    /** Transport groups were superseded by another range covering the same media. */
    COVERED,

    /** Transport groups were skipped because the publisher sequence moved backward. */
    REWIND,

    /** An expected transport sequence range was never delivered. */
    MISSING_SEQUENCE,
}

internal enum class TimelineResetReason {
    /** Publisher started a new epoch after rewinding its media sequence. */
    PUBLISHER_REWIND,

    /** Consecutive media timestamps differ by more than the configured maximum gap. */
    TIMESTAMP_GAP,

    /** A downstream decoder or renderer recovery requested a local timeline reset. */
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
        val gapUs: Long? = null,
    ) : TimelineDecision

    data class End(val error: PipelineError?) : TimelineDecision
}

/**
 * Sole authority for track epoch, freshness, timestamp-gap, and latency decisions.
 * The class is synchronous and deterministic; adapters supply all clock observations.
 */
internal class TrackTimeline(
    private val policy: TimelinePolicy,
    private val timeSource: TimeSource,
) {
    private var liveEdgeOffsetUs: Long? = null
    private var playbackPosition: Long? = null
    private var lastTimestamp: Long? = null

    var currentEpoch: Long? = null
        private set

    var targetLatencyUs: Long = policy.targetLatencyUs
        private set

    @Synchronized
    fun onIngest(event: IngestEvent): TimelineDecision = when (event) {
        is IngestEvent.Frame -> onFrame(event)
        is IngestEvent.GroupsSkipped -> TimelineDecision.Drop(
            reason = event.reason.toTimelineDropReason(),
            groupRange = event.fromSequence..event.toSequence,
        )
        is IngestEvent.Discontinuity -> resetForEpoch(event.epoch, resumeFrom = null)
        is IngestEvent.Closed -> TimelineDecision.End(event.error)
    }

    @Synchronized
    fun onPlaybackPosition(positionUs: Long) {
        require(positionUs >= 0L) { "positionUs must be non-negative" }
        playbackPosition = positionUs
    }

    @Synchronized
    fun requestReset(reason: TimelineResetReason = TimelineResetReason.DOWNSTREAM_RECOVERY): TimelineDecision.Reset {
        lastTimestamp = null
        liveEdgeOffsetUs = null
        playbackPosition = null
        return TimelineDecision.Reset(
            reason = reason,
            epoch = currentEpoch ?: 0L,
            resumeFrom = null,
        )
    }

    @Synchronized
    fun liveEdgeUs(): Long? {
        val offsetUs = liveEdgeOffsetUs ?: return null
        return addOrNull(timeSource.nanoTime() / NANOS_PER_MICROSECOND, offsetUs)
    }

    @Synchronized
    fun currentLatencyUs(): Long? {
        val edge = liveEdgeUs() ?: return null
        val playback = playbackPosition ?: return null
        return subtractClampedToZero(edge, playback)
    }

    @Synchronized
    fun setTargetLatency(us: Long) {
        require(us >= 0L) { "target latency must be non-negative" }
        targetLatencyUs = us
    }

    private fun onFrame(event: IngestEvent.Frame): TimelineDecision {
        val frame = event.frame
        val epoch = currentEpoch
        if (epoch != null && frame.epoch != epoch) {
            return resetForEpoch(frame.epoch, resumeFrom = frame, arrivalNanos = event.arrivalNanos)
        }
        if (epoch == null) {
            currentEpoch = frame.epoch
        }

        val previousTimestamp = lastTimestamp
        val gapUs = previousTimestamp?.let { absoluteDifferenceSaturated(frame.timestampUs, it) }
        if (gapUs != null && gapUs > policy.maxGapUs) {
            lastTimestamp = frame.timestampUs
            resetLiveEdge(frame.timestampUs, event.arrivalNanos)
            playbackPosition = null
            return TimelineDecision.Reset(
                reason = TimelineResetReason.TIMESTAMP_GAP,
                epoch = frame.epoch,
                resumeFrom = frame,
                gapUs = gapUs,
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
        recordLiveEdge(frame.timestampUs, event.arrivalNanos)
        return TimelineDecision.Admit(frame)
    }

    private fun resetForEpoch(
        epoch: Long,
        resumeFrom: TimedFrame?,
        arrivalNanos: Long? = null,
    ): TimelineDecision.Reset {
        require(epoch >= 0L) { "epoch must be non-negative" }
        currentEpoch = epoch
        lastTimestamp = resumeFrom?.timestampUs
        liveEdgeOffsetUs = null
        playbackPosition = null
        if (resumeFrom != null && arrivalNanos != null) {
            recordLiveEdge(resumeFrom.timestampUs, arrivalNanos)
        }
        return TimelineDecision.Reset(
            reason = TimelineResetReason.PUBLISHER_REWIND,
            epoch = epoch,
            resumeFrom = resumeFrom,
        )
    }

    private fun isOlderThanFreshnessBudget(timestampUs: Long, playbackUs: Long): Boolean {
        if (timestampUs >= playbackUs) return false
        val ageUs = subtractOrNull(playbackUs, timestampUs) ?: Long.MAX_VALUE
        return ageUs > policy.freshnessBudgetUs
    }

    private fun subtractClampedToZero(left: Long, right: Long): Long =
        if (left <= right) 0L else subtractOrNull(left, right) ?: Long.MAX_VALUE

    private fun recordLiveEdge(timestampUs: Long, arrivalNanos: Long) {
        val offsetUs = subtractOrNull(timestampUs, arrivalNanos / NANOS_PER_MICROSECOND) ?: return
        liveEdgeOffsetUs = maxOf(liveEdgeOffsetUs ?: Long.MIN_VALUE, offsetUs)
    }

    private fun resetLiveEdge(timestampUs: Long, arrivalNanos: Long) {
        liveEdgeOffsetUs = null
        recordLiveEdge(timestampUs, arrivalNanos)
    }

    private fun absoluteDifferenceSaturated(left: Long, right: Long): Long =
        if (left >= right) subtractOrNull(left, right) ?: Long.MAX_VALUE
        else subtractOrNull(right, left) ?: Long.MAX_VALUE

    private fun subtractOrNull(left: Long, right: Long): Long? = try {
        Math.subtractExact(left, right)
    } catch (_: ArithmeticException) {
        null
    }

    private fun addOrNull(left: Long, right: Long): Long? = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        null
    }

    private fun TransportSkipReason.toTimelineDropReason(): TimelineDropReason = when (this) {
        TransportSkipReason.LATENCY_BUDGET -> TimelineDropReason.LATENCY_BUDGET_SKIP
        TransportSkipReason.EVICTED -> TimelineDropReason.NETWORK_EVICTED
        TransportSkipReason.COVERED -> TimelineDropReason.COVERED
        TransportSkipReason.REWIND -> TimelineDropReason.REWIND
        TransportSkipReason.MISSING_SEQUENCE -> TimelineDropReason.MISSING_SEQUENCE
    }

    private companion object {
        const val NANOS_PER_MICROSECOND = 1_000L
    }
}
