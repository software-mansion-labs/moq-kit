package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoFreshnessGateTest {
    @Test
    fun frameAtConfiguredLatencyBoundaryRemainsPlayable() {
        val gate = VideoFreshnessGate()

        assertEquals(
            VideoFreshnessDecision.Accept,
            gate.evaluate(
                timestampUs = 900_000L,
                keyframe = true,
                playbackTimeUs = 1_000_000L,
                targetBufferingUs = 100_000L,
            ),
        )
    }

    @Test
    fun staleGopIsAbandonedUntilFreshKeyframe() {
        val gate = VideoFreshnessGate()

        assertEquals(
            VideoFreshnessDecision.DropAndReset,
            gate.evaluate(800_000L, true, 1_000_000L, 100_000L),
        )
        assertEquals(
            VideoFreshnessDecision.Drop,
            gate.evaluate(950_000L, false, 1_000_000L, 100_000L),
        )
        assertEquals(
            VideoFreshnessDecision.Accept,
            gate.evaluate(950_000L, true, 1_000_000L, 100_000L),
        )
    }

    @Test
    fun videoDrivenPlaybackDoesNotApplyAnAudioFreshnessCutoff() {
        val gate = VideoFreshnessGate()

        assertEquals(
            VideoFreshnessDecision.Accept,
            gate.evaluate(100_000L, true, playbackTimeUs = null, targetBufferingUs = 0L),
        )
    }
}
