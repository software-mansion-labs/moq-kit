package com.swmansion.moqkit.subscribe.internal.playback

internal sealed class VideoStallDecision {
    data class Wait(val delayNs: Long) : VideoStallDecision()
    object BeginStall : VideoStallDecision()
    object AlreadyStalled : VideoStallDecision()
    object WaitingForFrame : VideoStallDecision()
}

internal class VideoStallHorizon {
    companion object {
        private const val FALLBACK_VISIBLE_FRAME_DURATION_US = 33_333L
    }

    var playableInputFramesInFlight: Int = 0
        private set

    var lastVisibleFramePTSUs: Long? = null
        private set

    var lastVisibleFrameEndNs: Long? = null
        private set

    var hasPendingStallMarker: Boolean = false
        private set

    var isStalled: Boolean = false
        private set

    private var lastVisibleFrameIntervalUs: Long? = null

    fun recordCodecInputSubmitted(playable: Boolean) {
        if (playable) {
            playableInputFramesInFlight++
        }
    }

    fun recordCodecInputResolved(playable: Boolean) {
        if (playable && playableInputFramesInFlight > 0) {
            playableInputFramesInFlight--
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
        if (isStalled) {
            hasPendingStallMarker = false
            return VideoStallDecision.AlreadyStalled
        }

        if (playableInputFramesInFlight > 0) {
            hasPendingStallMarker = false
            return VideoStallDecision.WaitingForFrame
        }

        val endNs = lastVisibleFrameEndNs
        if (endNs != null && nowNs < endNs) {
            hasPendingStallMarker = true
            return VideoStallDecision.Wait(endNs - nowNs)
        }

        hasPendingStallMarker = false
        isStalled = true
        return VideoStallDecision.BeginStall
    }

    fun clearPendingStallMarker() {
        hasPendingStallMarker = false
    }

    fun reset() {
        playableInputFramesInFlight = 0
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
