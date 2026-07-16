package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.BufferDepth
import com.swmansion.moqkit.subscribe.DecoderFlushReason
import com.swmansion.moqkit.subscribe.DiscontinuityReason
import com.swmansion.moqkit.subscribe.DropReason
import com.swmansion.moqkit.subscribe.DropStage
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.RetargetDecision
import com.swmansion.moqkit.subscribe.SwitchPhase
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.RecoveryAttempt
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelineResetReason

/**
 * Emits renderer diagnostics to the [PipelineBus] for one media kind, keeping the paired
 * [PlaybackStatsTracker] drop counters in sync with the emitted drop events.
 */
internal class RendererTelemetry(
    private val mediaKind: PipelineMediaKind,
    private val metrics: PlaybackStatsTracker?,
    private val bus: PipelineBus?,
) {
    fun context(trackName: String, timestampNanos: Long = System.nanoTime()) = PipelineContext(
        trackId = trackName,
        mediaKind = mediaKind,
        timestampNanos = timestampNanos,
    )

    /** Records the dropped-frame metric and emits the matching [PipelineEvent.FrameDropped]. */
    fun frameDropped(
        trackName: String,
        stage: DropStage,
        reason: DropReason,
        count: Int = 1,
        ptsUs: Long? = null,
        bytes: Long = 0L,
        timestampNanos: Long = System.nanoTime(),
    ) {
        if (count <= 0) return
        when (mediaKind) {
            PipelineMediaKind.VIDEO -> metrics?.recordVideoFrameDropped(count)
            PipelineMediaKind.AUDIO -> metrics?.recordAudioFramesDropped(count)
        }
        bus?.emit(
            PipelineEvent.FrameDropped(
                context = context(trackName, timestampNanos),
                stage = stage,
                reason = reason,
                ptsUs = ptsUs,
                count = count,
                bytes = bytes,
            ),
        )
    }

    fun frameAdmitted(trackName: String, ptsUs: Long, bufferDepth: BufferDepth) {
        bus?.emit(
            PipelineEvent.FrameAdmitted(
                context = context(trackName),
                ptsUs = ptsUs,
                bufferDepth = bufferDepth,
            ),
        )
    }

    fun bufferDepth(trackName: String, depth: BufferDepth) {
        bus?.emit(
            PipelineEvent.BufferDepthChanged(
                context = context(trackName),
                depth = depth,
            ),
        )
    }

    fun decoderInputQueued(
        trackName: String,
        ptsUs: Long,
        timestampNanos: Long = System.nanoTime(),
    ) {
        bus?.emit(
            PipelineEvent.DecoderInputQueued(
                context = context(trackName, timestampNanos),
                ptsUs = ptsUs,
            ),
        )
    }

    fun decoderOutputReady(
        trackName: String,
        ptsUs: Long,
        timestampNanos: Long = System.nanoTime(),
    ) {
        bus?.emit(
            PipelineEvent.DecoderOutputReady(
                context = context(trackName, timestampNanos),
                ptsUs = ptsUs,
            ),
        )
    }

    fun frameRendered(
        trackName: String,
        ptsUs: Long,
        renderNanos: Long,
        timestampNanos: Long = System.nanoTime(),
    ) {
        bus?.emit(
            PipelineEvent.FrameRendered(
                context = context(trackName, timestampNanos),
                ptsUs = ptsUs,
                renderNanos = renderNanos,
            ),
        )
    }

    fun discontinuity(trackName: String, epoch: Long, reason: DiscontinuityReason) {
        bus?.emit(
            PipelineEvent.Discontinuity(
                context = context(trackName),
                epoch = epoch,
                reason = reason,
            ),
        )
    }

    fun decoderRecovery(trackName: String, attempt: RecoveryAttempt) {
        bus?.emit(
            PipelineEvent.DecoderRecovery(
                context = context(trackName),
                attempt = attempt.attempt,
                step = attempt.step,
                trigger = attempt.trigger,
            ),
        )
    }

    fun decoderFlushed(
        trackName: String,
        reason: DecoderFlushReason,
        trigger: String,
        droppedFrames: Int,
    ) {
        bus?.emit(
            PipelineEvent.DecoderFlushed(
                context = context(trackName),
                reason = reason,
                trigger = trigger,
                droppedFrames = droppedFrames,
            ),
        )
    }

    fun switchProgress(trackName: String, phase: SwitchPhase) {
        bus?.emit(
            PipelineEvent.SwitchProgress(
                context = context(trackName),
                phase = phase,
            ),
        )
    }

    fun clockRetarget(trackName: String, decision: RetargetDecision) {
        bus?.emit(
            PipelineEvent.ClockRetarget(
                context = context(trackName),
                decision = decision,
            ),
        )
    }
}

internal fun timelineResetTrigger(reason: TimelineResetReason, gapUs: Long?): String =
    if (gapUs == null) reason.name else "${reason.name} gapUs=$gapUs"
