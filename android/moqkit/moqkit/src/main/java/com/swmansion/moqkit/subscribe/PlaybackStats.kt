package com.swmansion.moqkit.subscribe

import java.time.Duration

/**
 * A point-in-time snapshot of playback quality metrics, available via [Player.stats].
 *
 * These values are intended for diagnostics and quality UI. All nullable fields use
 * `null` to mean the metric has not yet been measured or the media kind is inactive.
 */
data class PlaybackStats(
    val audioLatency: Duration?,
    val videoLatency: Duration?,
    val audioStalls: StallStats?,
    val videoStalls: StallStats?,
    val audioBitrateKbps: Double?,
    val videoBitrateKbps: Double?,
    val timeToFirst: TimeToFirstPlaybackStats,
    val videoFps: Double?,
    val audioFramesDropped: Long?,
    val videoFramesDropped: Long?,
    val audioRingBuffer: Duration?,
    val videoJitterBuffer: Duration?,
    val audioArrival: FrameArrivalStats? = null,
    val videoArrival: FrameArrivalStats? = null,
    val audioSwitches: TrackSwitchStats? = null,
    val videoSwitches: TrackSwitchStats? = null,
    val videoDecodeStats: VideoDecodeStats? = null,
) {
    companion object {
        internal val Empty = PlaybackStats(
            audioLatency = null,
            videoLatency = null,
            audioStalls = null,
            videoStalls = null,
            audioBitrateKbps = null,
            videoBitrateKbps = null,
            timeToFirst = TimeToFirstPlaybackStats.Empty,
            videoFps = null,
            audioFramesDropped = null,
            videoFramesDropped = null,
            audioRingBuffer = null,
            videoJitterBuffer = null,
            audioArrival = null,
            videoArrival = null,
            audioSwitches = null,
            videoSwitches = null,
            videoDecodeStats = null,
        )
    }
}

/** Startup timing milestones from [Player.play]. */
data class TimeToFirstPlaybackStats(
    val audioFrame: Duration?,
    val videoFrame: Duration?,
    val audioPlaying: Duration?,
    val videoPlaying: Duration?,
) {
    companion object {
        internal val Empty = TimeToFirstPlaybackStats(
            audioFrame = null,
            videoFrame = null,
            audioPlaying = null,
            videoPlaying = null,
        )
    }
}

/**
 * Arrival timing diagnostics for one received media stream.
 */
data class FrameArrivalStats(
    val receivedFramesPerSecond: Double?,
    val averageInterarrival: Duration?,
    val maxInterarrival: Duration?,
    val slowArrivalCount: Long,
    val fastArrivalCount: Long,
    val outOfOrderCount: Long,
    val maxOutOfOrderDelta: Duration?,
    val discontinuityCount: Long,
    val maxDiscontinuityGap: Duration?,
)

/**
 * MediaCodec decode timing statistics for the currently active video track.
 *
 * Android-only diagnostic surface.
 */
data class VideoDecodeStats(
    val trackName: String,
    val sampleCount: Long,
    val min: Duration,
    val max: Duration,
    val average: Duration,
    val last: Duration,
    val inFlightBufferCount: Int = 0,
    val minOutputInterval: Duration? = null,
    val averageOutputInterval: Duration? = null,
    val maxOutputInterval: Duration? = null,
)

/** Stall / rebuffering statistics for one media pipeline. */
data class StallStats(
    val count: Long,
    val totalDuration: Duration,
    val rebufferingRatio: Double,
)

/** Track switch diagnostics for one media kind. */
data class TrackSwitchStats(
    val requestedCount: Long,
    val completedCount: Long,
    val latest: TrackSwitch?,
)

/** Milestones for a single track switch attempt. */
data class TrackSwitch(
    val trackName: String?,
    val isCompleted: Boolean,
    val errorMessage: String?,
    val switchToReady: Duration?,
    val readyToPlaying: Duration?,
    val switchToPlaying: Duration?,
    val switchToActive: Duration?,
)
