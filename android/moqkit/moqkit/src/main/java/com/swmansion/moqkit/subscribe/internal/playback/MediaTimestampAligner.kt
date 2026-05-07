package com.swmansion.moqkit.subscribe.internal.playback

import kotlin.math.abs

/**
 * Correlates raw video timestamps with the audio playback timestamp domain.
 */
internal class MediaTimestampAligner(
    val audioLiveEdge: MediaLiveEdge = MediaLiveEdge(),
    val videoLiveEdge: MediaLiveEdge = MediaLiveEdge(),
) {
    fun videoOffset(threshold: Long): Long? {
        val audioTime = audioLiveEdge.estimatedLivePTS() ?: return null
        val videoTime = videoLiveEdge.estimatedLivePTS() ?: return null
        val offset = try {
            Math.subtractExact(audioTime, videoTime)
        } catch (_: ArithmeticException) {
            return null
        }
        return if (absoluteValueExceeds(offset, threshold)) offset else null
    }

    fun audioTime(videoTime: Long, threshold: Long): Long {
        val offset = videoOffset(threshold) ?: return videoTime
        return try {
            Math.addExact(videoTime, offset).takeIf { it >= 0L } ?: videoTime
        } catch (_: ArithmeticException) {
            videoTime
        }
    }

    fun videoTime(audioTime: Long, threshold: Long): Long {
        val offset = videoOffset(threshold) ?: return audioTime
        return try {
            Math.subtractExact(audioTime, offset).takeIf { it >= 0L } ?: audioTime
        } catch (_: ArithmeticException) {
            audioTime
        }
    }

    private fun absoluteValueExceeds(value: Long, threshold: Long): Boolean {
        if (threshold < 0L || value == Long.MIN_VALUE) return true
        return abs(value) > threshold
    }
}
