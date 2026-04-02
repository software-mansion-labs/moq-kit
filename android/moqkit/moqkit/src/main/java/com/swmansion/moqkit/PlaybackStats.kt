package com.swmansion.moqkit

/**
 * A point-in-time snapshot of playback health metrics, available via [MoQPlayer.stats].
 *
 * All fields are nullable — a `null` value means the metric has not yet been measured
 * (e.g. no frames received yet) rather than that the metric is zero.
 *
 * @property audioLatencyMs End-to-end audio latency in milliseconds
 *   (difference between the latest ingested PTS and the current playback position).
 * @property videoLatencyMs End-to-end video latency in milliseconds.
 * @property audioStalls Stall statistics for the audio pipeline since playback started.
 * @property videoStalls Stall statistics for the video pipeline since playback started.
 * @property audioBitrateKbps Smoothed incoming audio bitrate in kilobits per second.
 * @property videoBitrateKbps Smoothed incoming video bitrate in kilobits per second.
 * @property timeToFirstAudioFrameMs Milliseconds from [MoQPlayer.play] until the first
 *   decoded audio frame was submitted to the renderer.
 * @property timeToFirstVideoFrameMs Milliseconds from [MoQPlayer.play] until the first
 *   decoded video frame was submitted to the renderer.
 * @property videoFps Smoothed rendered video frame rate.
 * @property audioFramesDropped Total audio frames dropped due to buffer overflow or stale PTS.
 * @property videoFramesDropped Total video frames dropped due to buffer overflow or stale PTS.
 * @property audioRingBufferMs Current fill level of the audio ring buffer in milliseconds.
 * @property videoJitterBufferMs Current fill level of the video jitter buffer in milliseconds.
 */
data class PlaybackStats(
    val audioLatencyMs: Double?,
    val videoLatencyMs: Double?,
    val audioStalls: StallStats?,
    val videoStalls: StallStats?,
    val audioBitrateKbps: Double?,
    val videoBitrateKbps: Double?,
    val timeToFirstAudioFrameMs: Double?,
    val timeToFirstVideoFrameMs: Double?,
    val videoFps: Double?,
    val audioFramesDropped: Long?,
    val videoFramesDropped: Long?,
    val audioRingBufferMs: Double?,
    val videoJitterBufferMs: Double?,
)

/**
 * Stall / rebuffering statistics for one media pipeline.
 *
 * @property count Total number of stall events since playback started.
 * @property totalDurationMs Cumulative stall duration in milliseconds.
 * @property rebufferingRatio Fraction of total playback time spent stalled (0.0–1.0).
 */
data class StallStats(
    val count: Long,
    val totalDurationMs: Double,
    val rebufferingRatio: Double,
)
