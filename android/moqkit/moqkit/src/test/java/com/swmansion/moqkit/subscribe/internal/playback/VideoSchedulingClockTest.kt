package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoSchedulingClockTest {
    @Test
    fun returnsClockWhenBehindPlayhead() {
        assertEquals(
            4_800_000L,
            clampSchedulingClockToVideoPlayhead(clockUs = 4_800_000L, videoPlayheadUs = 5_000_000L),
        )
    }

    @Test
    fun returnsClockWhenExactlyAtPlayhead() {
        assertEquals(
            5_000_000L,
            clampSchedulingClockToVideoPlayhead(clockUs = 5_000_000L, videoPlayheadUs = 5_000_000L),
        )
    }

    @Test
    fun clampsToPlayheadWhenClockOverran() {
        assertEquals(
            5_000_000L,
            clampSchedulingClockToVideoPlayhead(clockUs = 6_930_000L, videoPlayheadUs = 5_000_000L),
        )
    }

    @Test
    fun returnsClockWhenPlayheadUnknown() {
        assertEquals(
            6_930_000L,
            clampSchedulingClockToVideoPlayhead(clockUs = 6_930_000L, videoPlayheadUs = null),
        )
    }
}
