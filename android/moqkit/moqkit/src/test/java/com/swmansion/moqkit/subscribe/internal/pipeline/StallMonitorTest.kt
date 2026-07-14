package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StallMonitorTest {
    private val baseContext = PipelineContext("video/main", PipelineMediaKind.VIDEO, 0)
    private val policy = StallPolicy(
        arrivalGapUs = 1_000,
        decodeProgressUs = 1_000,
        renderProgressUs = 1_000,
        stallDebounceUs = 100,
    )

    @Test
    fun attributesNetworkIdleAndEndsWhenFramesResume() {
        val monitor = StallMonitor(baseContext, policy)
        monitor.onEvent(PipelineEvent.FrameArrived(baseContext, 0, null, null, 1))
        monitor.onEvent(PipelineEvent.BandwidthSample(baseContext, 0, null))

        assertTrue(monitor.evaluate(nowNanos = 1_050_000).isEmpty())
        val started = monitor.evaluate(nowNanos = 1_150_000).single() as PipelineEvent.StallStarted
        assertEquals(StallCause.NETWORK_IDLE, started.cause)

        monitor.onEvent(PipelineEvent.FrameArrived(baseContext.copy(timestampNanos = 1_200_000), 1, null, null, 1))
        monitor.onEvent(PipelineEvent.FrameRendered(baseContext.copy(timestampNanos = 1_200_000), 1, 1_200_000))
        val ended = monitor.evaluate(nowNanos = 1_200_000).single() as PipelineEvent.StallEnded
        assertEquals(StallCause.NETWORK_IDLE, ended.cause)
    }

    @Test
    fun attributesPolicyDecodeAndRenderStarvationToTheMostUpstreamStage() {
        val policyMonitor = StallMonitor(baseContext, policy)
        policyMonitor.onEvent(PipelineEvent.FrameArrived(baseContext, 0, null, null, 1))
        policyMonitor.onEvent(
            PipelineEvent.FrameDropped(baseContext, DropStage.TIMELINE, DropReason.STALE_VS_PLAYBACK),
        )
        assertEquals(
            StallCause.POLICY_STARVATION,
            startCause(policyMonitor, 150_000),
        )

        val decodeMonitor = StallMonitor(baseContext, policy)
        decodeMonitor.onEvent(PipelineEvent.FrameArrived(baseContext, 0, null, null, 1))
        decodeMonitor.onEvent(PipelineEvent.BufferDepthChanged(baseContext, BufferDepth(2, 20, 33)))
        assertEquals(StallCause.DECODE_STALL, startCause(decodeMonitor, 150_000))

        val renderMonitor = StallMonitor(baseContext, policy)
        renderMonitor.onEvent(PipelineEvent.FrameArrived(baseContext, 0, null, null, 1))
        renderMonitor.onEvent(PipelineEvent.DecoderOutputReady(baseContext, 0))
        assertEquals(StallCause.RENDER_STALL, startCause(renderMonitor, 150_000))
    }

    @Test
    fun switchWaitOverridesOtherAttribution() {
        val monitor = StallMonitor(baseContext, policy)
        monitor.onEvent(PipelineEvent.SwitchProgress(baseContext, SwitchPhase.PREPARING))

        assertEquals(StallCause.SWITCH_STALL, startCause(monitor, 150_000))
    }

    private fun startCause(monitor: StallMonitor, afterDebounceNanos: Long): StallCause {
        monitor.evaluate(nowNanos = 0)
        return (monitor.evaluate(nowNanos = afterDebounceNanos).single() as PipelineEvent.StallStarted).cause
    }
}
