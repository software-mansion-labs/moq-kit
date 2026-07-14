package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackTimelineTest {
    private val time = FakeTimeSource(1_000L)

    @Test
    fun admitsFramesAndTracksLiveEdgeAndLatency() {
        val timeline = TrackTimeline(
            policy = TimelinePolicy(maxGapUs = 500, freshnessBudgetUs = 1_000, targetLatencyUs = 100),
            timeSource = time,
        )

        assertTrue(timeline.onIngest(frame(1_000, epoch = 1)) is TimelineDecision.Admit)
        timeline.onPlaybackPosition(900)

        assertEquals(1_000L, timeline.liveEdgeUs())
        assertEquals(100L, timeline.currentLatencyUs())
        assertEquals(1L, timeline.currentEpoch)
    }

    @Test
    fun liveEdgeAdvancesWithMonotonicTimeAfterArrival() {
        val timeline = TrackTimeline(
            policy = TimelinePolicy(maxGapUs = 500, freshnessBudgetUs = 1_000),
            timeSource = time,
        )
        timeline.onIngest(frame(5_000, epoch = 1))

        time.advance(250_000)

        assertEquals(5_250L, timeline.liveEdgeUs())
    }

    @Test
    fun downstreamResetClearsLiveEdgeUntilAnotherFrameArrives() {
        val timeline = TrackTimeline(TimelinePolicy(), time)
        timeline.onIngest(frame(5_000, epoch = 1))

        timeline.requestReset()

        assertNull(timeline.liveEdgeUs())
    }

    @Test
    fun timestampGapHasOneResetAuthorityAndCarriesResumeFrame() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = 500, freshnessBudgetUs = 10_000),
            time,
        )
        timeline.onIngest(frame(1_000, epoch = 3))

        val decision = timeline.onIngest(frame(1_501, epoch = 3))

        val reset = decision as TimelineDecision.Reset
        assertEquals(TimelineResetReason.TIMESTAMP_GAP, reset.reason)
        assertEquals(1_501L, reset.resumeFrom?.timestampUs)
        assertEquals(3L, reset.epoch)
        assertEquals(501L, reset.gapUs)
    }

    @Test
    fun resetClearsTheOldPlaybackDomainBeforeFollowingFramesArrive() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = 500, freshnessBudgetUs = 100),
            time,
        )
        timeline.onIngest(frame(10_000, epoch = 3))
        timeline.onPlaybackPosition(9_900)

        assertTrue(timeline.onIngest(frame(1_000, epoch = 3)) is TimelineDecision.Reset)

        assertTrue(timeline.onIngest(frame(1_010, epoch = 3)) is TimelineDecision.Admit)
    }

    @Test
    fun timestampGapComparisonDoesNotOverflow() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = Long.MAX_VALUE - 1, freshnessBudgetUs = Long.MAX_VALUE),
            time,
        )
        timeline.onIngest(frame(Long.MIN_VALUE, epoch = 3))

        val decision = timeline.onIngest(frame(Long.MAX_VALUE, epoch = 3))

        assertTrue(decision is TimelineDecision.Reset)
    }

    @Test
    fun publisherEpochChangeResetsBeforeFreshnessIsEvaluated() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = 10_000, freshnessBudgetUs = 100),
            time,
        )
        timeline.onIngest(frame(10_000, epoch = 1))
        timeline.onPlaybackPosition(9_900)

        val decision = timeline.onIngest(frame(0, epoch = 2))

        val reset = decision as TimelineDecision.Reset
        assertEquals(TimelineResetReason.PUBLISHER_REWIND, reset.reason)
        assertEquals(0L, reset.resumeFrom?.timestampUs)
        assertEquals(2L, reset.epoch)
    }

    @Test
    fun staleFrameIsDroppedWithMachineReadableReason() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = 10_000, freshnessBudgetUs = 100),
            time,
        )
        timeline.onPlaybackPosition(1_000)

        val decision = timeline.onIngest(frame(899, epoch = 1))

        assertEquals(
            TimelineDropReason.STALE_VS_PLAYBACK,
            (decision as TimelineDecision.Drop).reason,
        )
        assertNull(timeline.liveEdgeUs())
    }

    @Test
    fun staleComparisonDoesNotOverflowForWrappedTransportTimestamps() {
        val timeline = TrackTimeline(
            TimelinePolicy(maxGapUs = Long.MAX_VALUE, freshnessBudgetUs = 100),
            time,
        )
        timeline.onPlaybackPosition(1_000L)

        val decision = timeline.onIngest(frame(Long.MIN_VALUE, epoch = 1))

        assertEquals(TimelineDropReason.STALE_VS_PLAYBACK, (decision as TimelineDecision.Drop).reason)
    }

    @Test
    fun explicitDiscontinuityAndTransportSkipStayTyped() {
        val timeline = TrackTimeline(TimelinePolicy(), time)

        val skipped = timeline.onIngest(
            IngestEvent.GroupsSkipped(4, 7, TransportSkipReason.EVICTED),
        )
        val reset = timeline.onIngest(IngestEvent.Discontinuity(epoch = 9))

        assertEquals(
            TimelineDropReason.NETWORK_EVICTED,
            (skipped as TimelineDecision.Drop).reason,
        )
        assertEquals(4L..7L, skipped.groupRange)
        assertEquals(TimelineResetReason.PUBLISHER_REWIND, (reset as TimelineDecision.Reset).reason)
        assertEquals(9L, reset.epoch)
    }

    @Test
    fun targetLatencyCanBeRetunedWithoutReconstructingTimeline() {
        val timeline = TrackTimeline(TimelinePolicy(targetLatencyUs = 100), time)

        timeline.setTargetLatency(250)

        assertEquals(250L, timeline.targetLatencyUs)
    }

    private fun frame(timestampUs: Long, epoch: Long): IngestEvent.Frame =
        IngestEvent.Frame(
            frame = TimedFrame(
                mediaFrame = MediaFrame(byteArrayOf(1), timestampUs, keyframe = true),
                epoch = epoch,
            ),
            arrivalNanos = time.nanoTime(),
        )
}
