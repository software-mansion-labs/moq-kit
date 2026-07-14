package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.PipelineEvent

/**
 * Pure per-track stall state machine. Attribution always selects the most-upstream
 * stage whose progress is missing while downstream work is starved.
 */
internal class StallMonitor(
    private val trackContext: PipelineContext,
    private val policy: StallPolicy,
) {
    private var lastIngestNanos: Long? = null
    private var lastAdmitNanos: Long? = null
    private var lastPolicyDropNanos: Long? = null
    private var lastDecodeOutputNanos: Long? = null
    private var lastRenderNanos: Long? = null
    private var bufferDepth = BufferDepth.Empty
    private var receiveBitsPerSecond: Long? = null
    private var switchPhase = SwitchPhase.STEADY

    private var candidate: Candidate? = null
    private var stalled: ActiveStall? = null

    fun onEvent(event: PipelineEvent) {
        if (event.context.trackId != trackContext.trackId ||
            event.context.mediaKind != trackContext.mediaKind
        ) {
            return
        }

        when (event) {
            is PipelineEvent.FrameArrived -> lastIngestNanos = event.context.timestampNanos
            is PipelineEvent.FrameAdmitted -> {
                lastAdmitNanos = event.context.timestampNanos
                bufferDepth = event.bufferDepth
            }
            is PipelineEvent.FrameDropped -> if (event.stage == DropStage.TIMELINE) {
                lastPolicyDropNanos = event.context.timestampNanos
            }
            is PipelineEvent.BufferDepthChanged -> bufferDepth = event.depth
            is PipelineEvent.DecoderOutputReady -> lastDecodeOutputNanos = event.context.timestampNanos
            is PipelineEvent.FrameRendered -> lastRenderNanos = event.context.timestampNanos
            is PipelineEvent.BandwidthSample -> receiveBitsPerSecond = event.receiveBitsPerSecond
            is PipelineEvent.SwitchProgress -> switchPhase = event.phase
            is PipelineEvent.DecoderInputQueued,
            is PipelineEvent.Discontinuity,
            is PipelineEvent.StallStarted,
            is PipelineEvent.StallEnded,
            is PipelineEvent.LatencySample,
            is PipelineEvent.DecoderRecovery,
            is PipelineEvent.ClockRetarget,
            is PipelineEvent.TransportClosed -> Unit
        }
    }

    fun evaluate(nowNanos: Long): List<PipelineEvent> {
        val cause = attribute(nowNanos)
        val active = stalled

        if (active != null) {
            if (cause == active.cause) return emptyList()
            stalled = null
            candidate = cause?.let { Candidate(it, nowNanos) }
            return listOf(
                PipelineEvent.StallEnded(
                    context = contextAt(nowNanos),
                    cause = active.cause,
                    durationMillis = nanosToMillis((nowNanos - active.startedNanos).coerceAtLeast(0L)),
                ),
            )
        }

        if (cause == null) {
            candidate = null
            return emptyList()
        }

        val currentCandidate = candidate
        if (currentCandidate == null || currentCandidate.cause != cause) {
            candidate = Candidate(cause, nowNanos)
            return emptyList()
        }

        val debounceNanos = microsToNanos(policy.stallDebounceUs)
        if (nowNanos - currentCandidate.sinceNanos < debounceNanos) return emptyList()

        stalled = ActiveStall(cause, nowNanos)
        candidate = null
        return listOf(PipelineEvent.StallStarted(contextAt(nowNanos), cause))
    }

    private fun attribute(nowNanos: Long): StallCause? {
        if (switchPhase == SwitchPhase.PREPARING) return StallCause.SWITCH_STALL

        if (!isFresh(lastIngestNanos, policy.arrivalGapUs, nowNanos)) {
            return if (receiveBitsPerSecond == 0L) StallCause.NETWORK_IDLE else StallCause.PUBLISHER_IDLE
        }

        val policyDrop = lastPolicyDropNanos
        if (bufferDepth.frames == 0 && policyDrop != null && policyDrop >= (lastAdmitNanos ?: Long.MIN_VALUE)) {
            return StallCause.POLICY_STARVATION
        }

        if (bufferDepth.frames > 0 && !isFresh(lastDecodeOutputNanos, policy.decodeProgressUs, nowNanos)) {
            return StallCause.DECODE_STALL
        }

        if (isFresh(lastDecodeOutputNanos, policy.decodeProgressUs, nowNanos) &&
            !isFresh(lastRenderNanos, policy.renderProgressUs, nowNanos)
        ) {
            return StallCause.RENDER_STALL
        }

        return null
    }

    private fun isFresh(timestampNanos: Long?, horizonUs: Long, nowNanos: Long): Boolean {
        val timestamp = timestampNanos ?: return false
        if (nowNanos <= timestamp) return true
        return nowNanos - timestamp < microsToNanos(horizonUs)
    }

    private fun contextAt(nowNanos: Long): PipelineContext = trackContext.copy(timestampNanos = nowNanos)

    private fun microsToNanos(microseconds: Long): Long = try {
        Math.multiplyExact(microseconds, 1_000L)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun nanosToMillis(nanoseconds: Long): Long = nanoseconds / 1_000_000L

    private data class Candidate(val cause: StallCause, val sinceNanos: Long)
    private data class ActiveStall(val cause: StallCause, val startedNanos: Long)
}
