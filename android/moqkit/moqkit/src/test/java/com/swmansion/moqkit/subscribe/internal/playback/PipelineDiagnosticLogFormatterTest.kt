package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.DecoderFlushReason
import com.swmansion.moqkit.subscribe.DropReason
import com.swmansion.moqkit.subscribe.DropStage
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import org.junit.Assert.assertEquals
import org.junit.Test

class PipelineDiagnosticLogFormatterTest {
    @Test
    fun includesVideoDropReasonAndFrameContext() {
        val entry = PipelineDiagnosticLogFormatter.format(
            PipelineEvent.FrameDropped(
                context = context(),
                stage = DropStage.RENDERER,
                reason = DropReason.LATE_RENDER,
                ptsUs = 42_000L,
                count = 2,
                bytes = 512L,
            ),
        )

        assertEquals(PipelineLogLevel.DEBUG, entry?.level)
        assertEquals(
            "Video frames dropped track='video/main' stage=RENDERER reason=LATE_RENDER " +
                "count=2 ptsUs=42000 bytes=512",
            entry?.message,
        )
    }

    @Test
    fun includesDecoderFlushReasonAndDroppedState() {
        val entry = PipelineDiagnosticLogFormatter.format(
            PipelineEvent.DecoderFlushed(
                context = context(),
                reason = DecoderFlushReason.TIMELINE_RESET,
                trigger = "TIMESTAMP_GAP gapUs=3000000",
                droppedFrames = 7,
            ),
        )

        assertEquals(PipelineLogLevel.WARN, entry?.level)
        assertEquals(
            "Video decoder flushed track='video/main' reason=TIMELINE_RESET " +
                "trigger='TIMESTAMP_GAP gapUs=3000000' droppedFrames=7",
            entry?.message,
        )
    }

    private fun context() = PipelineContext(
        trackId = "video/main",
        mediaKind = PipelineMediaKind.VIDEO,
        timestampNanos = 42L,
    )
}
