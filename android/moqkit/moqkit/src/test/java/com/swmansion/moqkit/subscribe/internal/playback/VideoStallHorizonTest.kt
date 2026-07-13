package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoStallHorizonTest {
    @Test
    fun codecInputTimesOutInsteadOfSuppressingStallForever() {
        val horizon = VideoStallHorizon(codecProgressTimeoutNs = 1_000_000_000L)

        horizon.recordCodecInputSubmitted(submittedAtNs = 1_000_000_000L)

        assertEquals(
            VideoStallDecision.Wait(delayNs = 500_000_000L),
            horizon.evaluateStallStart(nowNs = 1_500_000_000L),
        )
        assertEquals(
            VideoStallDecision.RecoverDecoder,
            horizon.evaluateStallStart(nowNs = 2_000_000_000L),
        )
    }

    @Test
    fun scheduledSurfaceFrameTimesOutWhenRenderIsNeverConfirmed() {
        val horizon = VideoStallHorizon(surfaceProgressTimeoutNs = 1_000_000_000L)

        horizon.recordSurfaceFrameSubmitted(
            playable = true,
            scheduledRenderTimeNs = 1_000_000_000L,
        )

        assertEquals(
            VideoStallDecision.Wait(delayNs = 500_000_000L),
            horizon.evaluateStallStart(nowNs = 1_500_000_000L),
        )
        assertEquals(
            VideoStallDecision.RecoverDecoder,
            horizon.evaluateStallStart(nowNs = 2_000_000_000L),
        )

        horizon.recordSurfaceFrameResolved(
            playable = true,
            scheduledRenderTimeNs = 1_000_000_000L,
        )
        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 2_000_000_000L),
        )
    }

    @Test
    fun futureVisibleHorizonDelaysStallStart() {
        val horizon = VideoStallHorizon()

        assertFalse(
            horizon.recordSurfaceFrameScheduled(
                playable = true,
                presentationTimeUs = 1_000_000L,
                renderTimeNs = 1_000_000_000L,
                frontFrameIntervalUs = 100_000L,
            ),
        )

        assertEquals(
            VideoStallDecision.Wait(delayNs = 50_000_000L),
            horizon.evaluateStallStart(nowNs = 1_050_000_000L),
        )
        assertTrue(horizon.hasPendingStallMarker)
        assertFalse(horizon.isStalled)
    }

    @Test
    fun stallStartsWhenVisibleHorizonHasElapsed() {
        val horizon = VideoStallHorizon()

        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_000_000L,
            renderTimeNs = 1_000_000_000L,
            frontFrameIntervalUs = 100_000L,
        )

        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 1_100_000_000L),
        )
        assertTrue(horizon.isStalled)
        assertFalse(horizon.hasPendingStallMarker)
    }

    @Test
    fun codecInputSuppressesStallUntilOutputResolves() {
        val horizon = VideoStallHorizon()

        horizon.recordCodecInputSubmitted(submittedAtNs = 0L)

        assertEquals(
            VideoStallDecision.Wait(delayNs = 500_000_000L),
            horizon.evaluateStallStart(nowNs = 500_000_000L),
        )
        assertFalse(horizon.hasPendingStallMarker)
        assertFalse(horizon.isStalled)

        horizon.recordCodecInputResolved()

        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 1_000_000_000L),
        )
    }

    @Test
    fun scheduledSurfaceFrameSuppressesStallUntilExpectedVisibleEnd() {
        val horizon = VideoStallHorizon()

        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_000_000L,
            renderTimeNs = 1_000_000_000L,
            frontFrameIntervalUs = 33_333L,
        )

        assertEquals(
            VideoStallDecision.Wait(delayNs = 23_333_000L),
            horizon.evaluateStallStart(nowNs = 1_010_000_000L),
        )
        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 1_033_333_000L),
        )
    }

    @Test
    fun nonPlayableFramesDoNotExtendVisibleHorizon() {
        val horizon = VideoStallHorizon()

        horizon.recordCodecInputSubmitted()
        assertFalse(
            horizon.recordSurfaceFrameScheduled(
                playable = false,
                presentationTimeUs = 1_000_000L,
                renderTimeNs = 1_000_000_000L,
                frontFrameIntervalUs = 100_000L,
            ),
        )

        assertEquals(1, horizon.codecInputFramesInFlight)
        assertNull(horizon.lastVisibleFramePTSUs)
        assertNull(horizon.lastVisibleFrameEndNs)
        horizon.recordCodecInputResolved()
        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 1_000_000_000L),
        )
    }

    @Test
    fun previousPtsDeltaIsUsedWhenFrontIntervalIsUnavailable() {
        val horizon = VideoStallHorizon()

        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_000_000L,
            renderTimeNs = 1_000_000_000L,
            frontFrameIntervalUs = 40_000L,
        )
        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_060_000L,
            renderTimeNs = 1_060_000_000L,
            frontFrameIntervalUs = null,
        )

        assertEquals(1_120_000_000L, horizon.lastVisibleFrameEndNs)
    }

    @Test
    fun activeStallEndsOnlyWhenPlayableFrameIsScheduled() {
        val horizon = VideoStallHorizon()

        assertEquals(
            VideoStallDecision.BeginStall,
            horizon.evaluateStallStart(nowNs = 1_000_000_000L),
        )
        assertTrue(horizon.isStalled)

        assertFalse(
            horizon.recordSurfaceFrameScheduled(
                playable = false,
                presentationTimeUs = 1_000_000L,
                renderTimeNs = 1_000_000_000L,
                frontFrameIntervalUs = 33_333L,
            ),
        )
        assertTrue(horizon.isStalled)

        assertTrue(
            horizon.recordSurfaceFrameScheduled(
                playable = true,
                presentationTimeUs = 1_033_333L,
                renderTimeNs = 1_033_333_000L,
                frontFrameIntervalUs = 33_333L,
            ),
        )
        assertFalse(horizon.isStalled)
    }

    @Test
    fun resetClearsState() {
        val horizon = VideoStallHorizon()

        horizon.recordCodecInputSubmitted()
        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_000_000L,
            renderTimeNs = 1_000_000_000L,
            frontFrameIntervalUs = 100_000L,
        )
        horizon.evaluateStallStart(nowNs = 1_050_000_000L)

        horizon.reset()

        assertEquals(0, horizon.codecInputFramesInFlight)
        assertNull(horizon.lastVisibleFramePTSUs)
        assertNull(horizon.lastVisibleFrameEndNs)
        assertFalse(horizon.hasPendingStallMarker)
        assertFalse(horizon.isStalled)
    }
}

class DecoderRecoveryBudgetTest {
    @Test
    fun rejectsThirdRecoveryInsideWindowAndExpiresOldAttempts() {
        val budget = DecoderRecoveryBudget(
            maxRecoveries = 2,
            windowNs = 10_000_000_000L,
        )

        assertTrue(budget.tryAcquire(nowNs = 0L))
        assertTrue(budget.tryAcquire(nowNs = 1_000_000_000L))
        assertFalse(budget.tryAcquire(nowNs = 9_999_999_999L))
        assertTrue(budget.tryAcquire(nowNs = 10_000_000_000L))
    }

    @Test
    fun clearAllowsRecoveryImmediately() {
        val budget = DecoderRecoveryBudget(maxRecoveries = 1, windowNs = 10L)

        assertTrue(budget.tryAcquire(nowNs = 0L))
        assertFalse(budget.tryAcquire(nowNs = 1L))

        budget.clear()

        assertTrue(budget.tryAcquire(nowNs = 1L))
    }
}
