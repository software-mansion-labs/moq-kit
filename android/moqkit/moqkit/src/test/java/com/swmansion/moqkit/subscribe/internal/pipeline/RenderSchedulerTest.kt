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

    @Test
    fun controllerExecutesRenderVerdictThroughSink() {
        val sink = RecordingRenderSink()
        val controller = RenderController(scheduler(clockPositionUs = 1_000), sink)
        val frame = DecodedFrame(ptsUs = 1_400, handle = 7)

        val result = controller.process(frame, nowNanos = 10_000)

        assertEquals(RenderExecution.Rendered(renderNanos = 410_000, confirmed = true), result)
        assertEquals(listOf(frame to 410_000L), sink.rendered)
        assertTrue(sink.dropped.isEmpty())
    }

    @Test
    fun controllerDropsLateFrameThroughSink() {
        val sink = RecordingRenderSink()
        val controller = RenderController(scheduler(clockPositionUs = 1_000), sink)
        val frame = DecodedFrame(ptsUs = 949, handle = 7)

        val result = controller.process(frame, nowNanos = 10_000)

        assertEquals(RenderExecution.DroppedLate(latenessUs = 51), result)
        assertEquals(listOf(frame), sink.dropped)
        assertTrue(sink.rendered.isEmpty())
    }

    @Test
    fun controllerLeavesHeldFrameOwnedByCaller() {
        val sink = RecordingRenderSink()
        val controller = RenderController(scheduler(clockPositionUs = 1_000), sink)
        val frame = DecodedFrame(ptsUs = 1_501, handle = 7)

        val result = controller.process(frame, nowNanos = 10_000)

        assertEquals(RenderExecution.Held(recheckAfterUs = 1), result)
        assertTrue(sink.rendered.isEmpty())
        assertTrue(sink.dropped.isEmpty())
    }

    private fun scheduler(clockPositionUs: Long?): RenderScheduler {
        val clock = PlaybackClock(
            ClockPolicy(),
            FakeTimeSource(0),
            videoDriver = object : AdjustableClockDriver {
                override fun positionUs(): Long? = clockPositionUs
                override fun setRate(rate: Double) = Unit
                override fun setPositionAndRate(positionUs: Long, rate: Double) = Unit
                override fun reset() = Unit
            },
        )
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

    private class RecordingRenderSink : RenderSink {
        val rendered = mutableListOf<Pair<DecodedFrame, Long>>()
        val dropped = mutableListOf<DecodedFrame>()

        override fun render(frame: DecodedFrame, atNanos: Long): Boolean {
            rendered += frame to atNanos
            return true
        }

        override fun drop(frame: DecodedFrame) {
            dropped += frame
        }
    }
}
