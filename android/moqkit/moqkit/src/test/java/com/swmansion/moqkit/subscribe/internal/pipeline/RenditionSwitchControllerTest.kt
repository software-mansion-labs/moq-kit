package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Test

class RenditionSwitchControllerTest {
    private val policy = SwitchPolicy(
        keyframeTimeoutUs = 5_000,
        cutInWindowUs = 500,
        flushThresholdUs = 2_000,
    )

    @Test
    fun nearbyKeyframeCutsInAfterActiveTrackReachesIt() {
        val controller = RenditionSwitchController(policy)
        controller.begin("high")

        assertEquals(
            SwitchDecision.Wait,
            controller.onKeyframeAvailable(lastFedPtsUs = 1_000, keyframePtsUs = 900),
        )
        assertEquals(SwitchDecision.Wait, controller.onActiveProgress(899))
        assertEquals(SwitchDecision.CutIn(900), controller.onActiveProgress(900))
    }

    @Test
    fun distantKeyframeRequestsFlushSwap() {
        val controller = RenditionSwitchController(policy)
        controller.begin("high")

        assertEquals(
            SwitchDecision.FlushSwap,
            controller.onKeyframeAvailable(lastFedPtsUs = 3_001, keyframePtsUs = 1_000),
        )
    }

    @Test
    fun timeoutAbortsPreparationAndKeepsCurrentTrack() {
        val controller = RenditionSwitchController(policy)
        controller.begin("high")

        assertEquals(SwitchDecision.Abort("high"), controller.onTimeout())
        assertEquals(SwitchState.Steady, controller.state)
    }

    @Test
    fun completingSwapReturnsToSteady() {
        val controller = RenditionSwitchController(policy)
        controller.begin("high")
        controller.onKeyframeAvailable(lastFedPtsUs = 3_001, keyframePtsUs = 1_000)

        controller.complete()

        assertEquals(SwitchState.Steady, controller.state)
    }

    @Test
    fun stalePendingDeltaFramesAreDiscardedOutsideCutInWindow() {
        val controller = RenditionSwitchController(policy)

        assertEquals(true, controller.shouldDiscardPendingDelta(lastFedPtsUs = 1_000, framePtsUs = 499))
        assertEquals(false, controller.shouldDiscardPendingDelta(lastFedPtsUs = 1_000, framePtsUs = 500))
    }
}
