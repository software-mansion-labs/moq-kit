package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RenderSchedulerTest {
    @Test
    fun dropsLateFramesWithMeasuredLateness() {
        val scheduler = scheduler(clockPositionUs = 1_000)

        val verdict = scheduler.verdict(DecodedFrame(ptsUs = 949), nowNanos = 10_000)

        assertEquals(RenderVerdict.DropLate(latenessUs = 51), verdict)
    }

    @Test
    fun holdsFramesBeyondTheDecodeAheadWindow() {
        val scheduler = scheduler(clockPositionUs = 1_000)

        val verdict = scheduler.verdict(DecodedFrame(ptsUs = 1_501), nowNanos = 10_000)

        assertEquals(RenderVerdict.Hold(recheckAfterUs = 1), verdict)
    }

    @Test
    fun schedulesWithinThePlatformMaximum() {
        val scheduler = scheduler(clockPositionUs = 1_000)

        val verdict = scheduler.verdict(DecodedFrame(ptsUs = 1_400), nowNanos = 10_000)

        assertEquals(RenderVerdict.RenderAt(renderNanos = 410_000), verdict)
    }

    @Test
    fun rendersImmediatelyWhenNoClockPositionExists() {
        val scheduler = scheduler(clockPositionUs = null)

        assertTrue(
            scheduler.verdict(DecodedFrame(ptsUs = 1_000), nowNanos = 42) is RenderVerdict.RenderAt,
        )
    }

    private fun scheduler(clockPositionUs: Long?): RenderScheduler {
        val clock = PlaybackClock(ClockPolicy(), FakeTimeSource(0))
        clock.attachDriver(object : ClockDriver {
            override fun positionUs(): Long? = clockPositionUs
        }, DriverKind.VIDEO)
        return RenderScheduler(
            RenderPolicy(
                maxAheadUs = 500,
                maxScheduleAheadNanos = 500_000,
                lateDropThresholdUs = 50,
                fallbackFrameDurationUs = 33,
            ),
            clock,
        )
    }
}
