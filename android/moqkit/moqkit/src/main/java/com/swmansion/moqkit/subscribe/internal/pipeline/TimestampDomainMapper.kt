package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlin.math.abs

/**
 * Maps timestamps between active audio and video timelines without owning either timeline.
 * The timelines remain the live-edge authorities; this class only compares their domains.
 */
internal class TimestampDomainMapper(
    private val audioTimeline: () -> TrackTimeline?,
    private val videoTimeline: () -> TrackTimeline?,
) {
    fun videoOffsetUs(thresholdUs: Long): Long? {
        require(thresholdUs >= 0L) { "thresholdUs must be non-negative" }
        val (audioEdgeUs, videoEdgeUs) = liveEdgesUs() ?: return null
        val offsetUs = subtractOrNull(audioEdgeUs, videoEdgeUs) ?: return null
        return offsetUs.takeIf { absoluteValueExceeds(it, thresholdUs) }
    }

    fun audioTimeUs(videoTimeUs: Long, thresholdUs: Long): Long {
        val offsetUs = videoOffsetUs(thresholdUs) ?: return videoTimeUs
        return addOrNull(videoTimeUs, offsetUs)?.takeIf { it >= 0L } ?: videoTimeUs
    }

    fun videoTimeUs(audioTimeUs: Long, thresholdUs: Long): Long {
        val offsetUs = videoOffsetUs(thresholdUs) ?: return audioTimeUs
        return subtractOrNull(audioTimeUs, offsetUs)?.takeIf { it >= 0L } ?: audioTimeUs
    }

    fun videoTimeUsOrNull(audioTimeUs: Long, thresholdUs: Long): Long? {
        require(thresholdUs >= 0L) { "thresholdUs must be non-negative" }
        val (audioEdgeUs, videoEdgeUs) = liveEdgesUs() ?: return null
        val offsetUs = subtractOrNull(audioEdgeUs, videoEdgeUs) ?: return null
        val effectiveOffsetUs = offsetUs.takeIf { absoluteValueExceeds(it, thresholdUs) } ?: 0L
        return subtractOrNull(audioTimeUs, effectiveOffsetUs)?.takeIf { it >= 0L } ?: audioTimeUs
    }

    private fun liveEdgesUs(): Pair<Long, Long>? {
        val audioEdgeUs = audioTimeline()?.liveEdgeUs() ?: return null
        val videoEdgeUs = videoTimeline()?.liveEdgeUs() ?: return null
        return audioEdgeUs to videoEdgeUs
    }

    private fun absoluteValueExceeds(value: Long, threshold: Long): Boolean =
        value == Long.MIN_VALUE || abs(value) > threshold

    private fun subtractOrNull(left: Long, right: Long): Long? = try {
        Math.subtractExact(left, right)
    } catch (_: ArithmeticException) {
        null
    }

    private fun addOrNull(left: Long, right: Long): Long? = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        null
    }
}
