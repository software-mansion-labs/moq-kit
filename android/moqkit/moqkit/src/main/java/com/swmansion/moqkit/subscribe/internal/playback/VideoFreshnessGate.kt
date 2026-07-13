package com.swmansion.moqkit.subscribe.internal.playback

internal enum class VideoFreshnessDecision {
    Accept,
    Drop,
    DropAndReset,
}

/** Keeps audio-driven video within the caller's target latency without decoding catch-up GOPs. */
internal class VideoFreshnessGate {
    private var waitingForKeyframe = false

    fun evaluate(
        timestampUs: Long,
        keyframe: Boolean,
        playbackTimeUs: Long?,
        targetBufferingUs: Long,
    ): VideoFreshnessDecision {
        val stale = playbackTimeUs?.let { playbackTime ->
            val cutoff = playbackTime - targetBufferingUs.coerceAtLeast(0L)
            timestampUs < cutoff
        } ?: false

        if (waitingForKeyframe) {
            if (!keyframe || stale) return VideoFreshnessDecision.Drop
            waitingForKeyframe = false
            return VideoFreshnessDecision.Accept
        }

        if (!stale) return VideoFreshnessDecision.Accept

        waitingForKeyframe = true
        return VideoFreshnessDecision.DropAndReset
    }

    fun forceResync() {
        waitingForKeyframe = true
    }
}
