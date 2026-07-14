package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class MediaClockTest {
    @Test
    fun audioDrivenClockCurrentTimeCanBeSetAndReset() {
        val clock = AudioDrivenClock()

        clock.setCurrentTimeUs(19_000L)
        assertEquals(19_000L, clock.currentTimeUs)

        clock.reset()
        assertEquals(0L, clock.currentTimeUs)
    }

    @Test
    fun videoDrivenClockAdvancesOnlyWhenRunning() {
        var wallClock = 1_000L
        val clock = VideoDrivenClock { wallClock }

        clock.setRate(1.0, timeUs = 10_000L)
        wallClock = 1_500L
        assertEquals(10_500L, clock.currentTimeUs)

        clock.setRate(0.0)
        wallClock = 3_000L
        assertEquals(10_500L, clock.currentTimeUs)
    }
}
