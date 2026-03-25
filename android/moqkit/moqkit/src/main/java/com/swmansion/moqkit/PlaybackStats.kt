package com.swmansion.moqkit

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

data class StallStats(
    val count: Long,
    val totalDurationMs: Double,
    val rebufferingRatio: Double,
)
