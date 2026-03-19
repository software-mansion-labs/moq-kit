package com.swmansion.moqkit

import android.media.AudioTrack

/**
 * Master clock derived from AudioTrack.getPlaybackHeadPosition().
 * Provides a monotonic microsecond timestamp anchored to the first audio PTS.
 * Will serve as the master clock for future video sync.
 */
internal class MediaTimebase {
    private var baseTimestampUs: Long = 0L
    private var sampleRate: Int = 0
    private var lastHeadPosition: Long = 0L
    private var hostTimeAtBaseNs: Long = 0L

    /** Current playback time in microseconds. */
    var currentTimeUs: Long = 0L
        private set

    /** Anchor the clock to the first audio timestamp and sample rate. */
    fun setBase(timestampUs: Long, sampleRate: Int) {
        this.baseTimestampUs = timestampUs
        this.sampleRate = sampleRate
        this.lastHeadPosition = 0L
        this.hostTimeAtBaseNs = System.nanoTime()
        this.currentTimeUs = timestampUs
    }

    /**
     * sets the current timestamp (PTS-wise).
     */
    fun update(timestampUs: Long) {
        currentTimeUs = timestampUs
    }

    /** Convert a PTS to host clock time in nanoseconds. */
    fun ptsToHostTimeNs(ptsUs: Long): Long =
        hostTimeAtBaseNs + (ptsUs - baseTimestampUs) * 1000

    fun reset() {
        baseTimestampUs = 0L
        sampleRate = 0
        lastHeadPosition = 0L
        hostTimeAtBaseNs = 0L
        currentTimeUs = 0L
    }
}
