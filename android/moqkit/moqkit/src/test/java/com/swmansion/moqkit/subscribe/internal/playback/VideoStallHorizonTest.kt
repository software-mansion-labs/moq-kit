package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoStallHorizonTest {
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
    fun playableCodecInputSuppressesStallUntilOutputResolves() {
        val horizon = VideoStallHorizon()

        horizon.recordCodecInputSubmitted(playable = true)

        assertEquals(
            VideoStallDecision.WaitingForFrame,
            horizon.evaluateStallStart(nowNs = 1_000_000_000L),
        )
        assertFalse(horizon.hasPendingStallMarker)
        assertFalse(horizon.isStalled)

        horizon.recordCodecInputResolved(playable = true)

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

        horizon.recordCodecInputSubmitted(playable = false)
        assertFalse(
            horizon.recordSurfaceFrameScheduled(
                playable = false,
                presentationTimeUs = 1_000_000L,
                renderTimeNs = 1_000_000_000L,
                frontFrameIntervalUs = 100_000L,
            ),
        )

        assertEquals(0, horizon.playableInputFramesInFlight)
        assertNull(horizon.lastVisibleFramePTSUs)
        assertNull(horizon.lastVisibleFrameEndNs)
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

        horizon.recordCodecInputSubmitted(playable = true)
        horizon.recordSurfaceFrameScheduled(
            playable = true,
            presentationTimeUs = 1_000_000L,
            renderTimeNs = 1_000_000_000L,
            frontFrameIntervalUs = 100_000L,
        )
        horizon.evaluateStallStart(nowNs = 1_050_000_000L)

        horizon.reset()

        assertEquals(0, horizon.playableInputFramesInFlight)
        assertNull(horizon.lastVisibleFramePTSUs)
        assertNull(horizon.lastVisibleFrameEndNs)
        assertFalse(horizon.hasPendingStallMarker)
        assertFalse(horizon.isStalled)
    }
}
