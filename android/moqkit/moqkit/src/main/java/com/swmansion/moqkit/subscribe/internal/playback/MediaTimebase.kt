package com.swmansion.moqkit.subscribe.internal.playback

/**
 * Shared playback clock driven by decoded audio playback.
 */
internal class MediaTimebase {
    /** Current playback time in microseconds. */
    @Volatile
    var currentTimeUs: Long = 0L
        private set

    fun setCurrentTimeUs(timestampUs: Long) {
        this.currentTimeUs = timestampUs
    }

    fun reset() {
        currentTimeUs = 0L
    }
}
