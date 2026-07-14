package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackClockTest {
    @Test
    fun audioDriverWinsAndVideoIsTheFallback() {
        val clock = PlaybackClock(ClockPolicy(), FakeTimeSource(0))
        val video = MutableClockDriver(100)
        val audio = MutableClockDriver(null)
        clock.attachDriver(video, DriverKind.VIDEO)
        clock.attachDriver(audio, DriverKind.AUDIO)

        assertEquals(100L, clock.nowMediaUs())

        audio.position = 200
        assertEquals(200L, clock.nowMediaUs())
    }

    @Test
    fun retargetReturnsNoOpNudgeOrJumpFromNamedPolicyBounds() {
        val clock = PlaybackClock(
            ClockPolicy(
                retargetToleranceUs = 20,
                jumpThresholdUs = 200,
                minRate = 0.9,
                maxRate = 1.1,
            ),
            FakeTimeSource(0),
        )
        val driver = MutableClockDriver(900)
        clock.attachDriver(driver, DriverKind.VIDEO)
        clock.onLiveEdge(1_000)

        assertEquals(RetargetDecision.NoOp, clock.retarget(targetLatencyUs = 90))
        assertTrue(clock.retarget(targetLatencyUs = 50) is RetargetDecision.Nudge)

        driver.position = 500
        assertEquals(RetargetDecision.Jump(900), clock.retarget(targetLatencyUs = 100))
    }

    private class MutableClockDriver(var position: Long?) : ClockDriver {
        override fun positionUs(): Long? = position
    }
}
