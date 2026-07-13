package com.swmansion.moqkit.subscribe.internal.playback

internal sealed class VideoStallDecision {
    data class Wait(val delayNs: Long) : VideoStallDecision()
    object BeginStall : VideoStallDecision()
    object AlreadyStalled : VideoStallDecision()
    object RecoverDecoder : VideoStallDecision()
}

internal class VideoStallHorizon(
    private val codecProgressTimeoutNs: Long = 1_000_000_000L,
    private val surfaceProgressTimeoutNs: Long = 1_000_000_000L,
) {
    companion object {
        private const val FALLBACK_VISIBLE_FRAME_DURATION_US = 33_333L
    }

    val codecInputFramesInFlight: Int
        get() = codecInputSubmissionTimesNs.size

    var lastVisibleFramePTSUs: Long? = null
        private set

    var lastVisibleFrameEndNs: Long? = null
        private set

    var hasPendingStallMarker: Boolean = false
        private set

    var isStalled: Boolean = false
        private set

    private var lastVisibleFrameIntervalUs: Long? = null
    private val codecInputSubmissionTimesNs = ArrayDeque<Long>()
    private val playableSurfaceRenderTimesNs = ArrayDeque<Long>()

    fun recordCodecInputSubmitted(
        submittedAtNs: Long = System.nanoTime(),
    ) {
        codecInputSubmissionTimesNs.addLast(submittedAtNs)
    }

    fun recordCodecInputResolved(
        submittedAtNs: Long? = null,
    ) {
        if (submittedAtNs != null) {
            codecInputSubmissionTimesNs.remove(submittedAtNs)
        } else if (codecInputSubmissionTimesNs.isNotEmpty()) {
            codecInputSubmissionTimesNs.removeFirst()
        }
    }

    fun recordSurfaceFrameSubmitted(
        playable: Boolean,
        scheduledRenderTimeNs: Long,
    ) {
        if (playable) {
            playableSurfaceRenderTimesNs.addLast(scheduledRenderTimeNs)
        }
    }

    fun recordSurfaceFrameResolved(
        playable: Boolean,
        scheduledRenderTimeNs: Long,
    ) {
        if (playable) {
            playableSurfaceRenderTimesNs.remove(scheduledRenderTimeNs)
        }
    }

    fun recordSurfaceFrameScheduled(
        playable: Boolean,
        presentationTimeUs: Long,
        renderTimeNs: Long,
        frontFrameIntervalUs: Long?,
    ): Boolean {
        if (!playable || presentationTimeUs < 0L || renderTimeNs < 0L) {
            return false
        }

        val visibleFrameIntervalUs = lastVisibleFramePTSUs?.let { previousPTSUs ->
            if (presentationTimeUs > previousPTSUs) presentationTimeUs - previousPTSUs else null
        }
        val durationUs =
            validDurationUs(frontFrameIntervalUs)
                ?: visibleFrameIntervalUs
                ?: lastVisibleFrameIntervalUs
                ?: FALLBACK_VISIBLE_FRAME_DURATION_US

        if (visibleFrameIntervalUs != null) {
            lastVisibleFrameIntervalUs = visibleFrameIntervalUs
        }
        lastVisibleFramePTSUs = presentationTimeUs
        lastVisibleFrameEndNs = addClamping(renderTimeNs, multiplyClamping(durationUs, 1_000L))
        hasPendingStallMarker = false

        if (!isStalled) {
            return false
        }
        isStalled = false
        return true
    }

    fun evaluateStallStart(nowNs: Long): VideoStallDecision {
        val codecDeadlineNs = codecInputSubmissionTimesNs.minOrNull()?.let {
            addClamping(it, codecProgressTimeoutNs)
        }
        val surfaceDeadlineNs = playableSurfaceRenderTimesNs.minOrNull()?.let {
            addClamping(it, surfaceProgressTimeoutNs)
        }
        val progressDeadlineNs = when {
            codecDeadlineNs == null -> surfaceDeadlineNs
            surfaceDeadlineNs == null -> codecDeadlineNs
            else -> minOf(codecDeadlineNs, surfaceDeadlineNs)
        }

        if (isStalled) {
            hasPendingStallMarker = false
            if (progressDeadlineNs != null) {
                return if (nowNs >= progressDeadlineNs) {
                    VideoStallDecision.RecoverDecoder
                } else {
                    VideoStallDecision.Wait(progressDeadlineNs - nowNs)
                }
            }
            return VideoStallDecision.AlreadyStalled
        }

        val endNs = lastVisibleFrameEndNs
        if (endNs != null && nowNs < endNs) {
            hasPendingStallMarker = true
            val nextDeadlineNs = progressDeadlineNs?.coerceAtMost(endNs) ?: endNs
            return VideoStallDecision.Wait((nextDeadlineNs - nowNs).coerceAtLeast(0L))
        }

        if (endNs == null && progressDeadlineNs != null) {
            hasPendingStallMarker = false
            return if (nowNs >= progressDeadlineNs) {
                VideoStallDecision.RecoverDecoder
            } else {
                VideoStallDecision.Wait(progressDeadlineNs - nowNs)
            }
        }

        hasPendingStallMarker = false
        isStalled = true
        return VideoStallDecision.BeginStall
    }

    fun clearPendingStallMarker() {
        hasPendingStallMarker = false
    }

    fun beginStallNow(): Boolean {
        hasPendingStallMarker = false
        if (isStalled) return false
        isStalled = true
        return true
    }

    fun reset() {
        codecInputSubmissionTimesNs.clear()
        playableSurfaceRenderTimesNs.clear()
        lastVisibleFramePTSUs = null
        lastVisibleFrameEndNs = null
        hasPendingStallMarker = false
        isStalled = false
        lastVisibleFrameIntervalUs = null
    }

    private fun validDurationUs(durationUs: Long?): Long? =
        durationUs?.takeIf { it > 0L }

    private fun addClamping(lhs: Long, rhs: Long): Long =
        try {
            Math.addExact(lhs, rhs)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }

    private fun multiplyClamping(lhs: Long, rhs: Long): Long =
        try {
            Math.multiplyExact(lhs, rhs)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
}
