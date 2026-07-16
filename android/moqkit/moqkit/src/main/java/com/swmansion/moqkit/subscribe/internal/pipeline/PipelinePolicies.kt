package com.swmansion.moqkit.subscribe.internal.pipeline

/** Timeline admission and reset thresholds, expressed in microseconds. */
internal data class TimelinePolicy(
    val maxGapUs: Long = 500_000L,
    val freshnessBudgetUs: Long = 1_000_000L,
    val targetLatencyUs: Long = 100_000L,
) {
    init {
        require(maxGapUs >= 0L) { "maxGapUs must be non-negative" }
        require(freshnessBudgetUs >= 0L) { "freshnessBudgetUs must be non-negative" }
        require(targetLatencyUs >= 0L) { "targetLatencyUs must be non-negative" }
    }
}

/** Hard bounds for the single compressed-frame buffer preceding decode. */
internal data class AdmissionPolicy(
    val maxBytes: Long = 64L * 1024L * 1024L,
    val maxFrames: Int = 1_024,
    val maxDurationUs: Long = 5_000_000L,
    val evictWholeGops: Boolean = true,
    val requireKeyframeAfterReset: Boolean = true,
) {
    init {
        require(maxBytes > 0L) { "maxBytes must be positive" }
        require(maxFrames > 0) { "maxFrames must be positive" }
        require(maxDurationUs > 0L) { "maxDurationUs must be positive" }
    }
}

/** Decoder recovery budget and ordered recovery mechanism. */
internal data class RecoveryPolicy(
    val maxRecoveries: Int = 2,
    val windowNanos: Long = 10_000_000_000L,
    val strategy: List<RecoveryStep> = listOf(RecoveryStep.FLUSH, RecoveryStep.REBUILD, RecoveryStep.FAIL),
) {
    init {
        require(maxRecoveries >= 0) { "maxRecoveries must be non-negative" }
        require(windowNanos > 0L) { "windowNanos must be positive" }
        require(strategy.isNotEmpty()) { "strategy must not be empty" }
    }
}

/** Decode-ahead and display scheduling thresholds. */
internal data class RenderPolicy(
    val maxAheadUs: Long = 500_000L,
    val maxScheduleAheadNanos: Long = 500_000_000L,
    val lateDropThresholdUs: Long = 50_000L,
    val fallbackFrameDurationUs: Long = 33_333L,
) {
    init {
        require(maxAheadUs >= 0L) { "maxAheadUs must be non-negative" }
        require(maxScheduleAheadNanos >= 0L) { "maxScheduleAheadNanos must be non-negative" }
        require(lateDropThresholdUs >= 0L) { "lateDropThresholdUs must be non-negative" }
        require(fallbackFrameDurationUs > 0L) { "fallbackFrameDurationUs must be positive" }
    }
}

/**
 * Playback-clock retargeting thresholds and bounded rate nudges.
 *
 * Errors within [retargetToleranceUs] leave the clock at normal speed. Errors at or beyond
 * [jumpThresholdUs] jump directly to the target position. Errors between those thresholds
 * are corrected gradually with a rate bounded by [minRate] and [maxRate].
 *
 * @property retargetToleranceUs Maximum clock error that requires no position correction.
 * @property jumpThresholdUs Minimum clock error corrected with an immediate position jump.
 * @property minRate Slowest rate used when the clock is ahead of its target position.
 * @property maxRate Fastest rate used when the clock is behind its target position.
 */
internal data class ClockPolicy(
    val retargetToleranceUs: Long = 20_000L,
    val jumpThresholdUs: Long = 500_000L,
    val minRate: Double = 0.95,
    val maxRate: Double = 1.05,
) {
    init {
        require(retargetToleranceUs >= 0L) { "retargetToleranceUs must be non-negative" }
        require(jumpThresholdUs >= retargetToleranceUs) { "jumpThresholdUs must cover the tolerance" }
        require(
            minRate.isFinite() && maxRate.isFinite() &&
                minRate > 0.0 && minRate <= 1.0 && maxRate >= 1.0,
        ) { "clock rate bounds must be finite and contain normal playback speed" }
    }
}

/** Liveness horizons used by the pure stall-attribution state machine. */
internal data class StallPolicy(
    val arrivalGapUs: Long = 1_000_000L,
    val decodeProgressUs: Long = 1_000_000L,
    val renderProgressUs: Long = 1_000_000L,
    val stallDebounceUs: Long = 100_000L,
) {
    init {
        require(arrivalGapUs > 0L) { "arrivalGapUs must be positive" }
        require(decodeProgressUs > 0L) { "decodeProgressUs must be positive" }
        require(renderProgressUs > 0L) { "renderProgressUs must be positive" }
        require(stallDebounceUs >= 0L) { "stallDebounceUs must be non-negative" }
    }
}

/** Rendition-switch thresholds formerly embedded in VideoRenderer. */
internal data class SwitchPolicy(
    val keyframeTimeoutUs: Long = 5_000_000L,
    val cutInWindowUs: Long = 500_000L,
    val flushThresholdUs: Long = 2_000_000L,
) {
    init {
        require(keyframeTimeoutUs > 0L) { "keyframeTimeoutUs must be positive" }
        require(cutInWindowUs >= 0L) { "cutInWindowUs must be non-negative" }
        require(flushThresholdUs >= cutInWindowUs) { "flushThresholdUs must cover the cut-in window" }
    }
}

/** Publish-side queue and demand limits. */
internal data class BackpressurePolicy(
    val maxPublishLatencyUs: Long = 500_000L,
    val maxQueuedFrames: Int = 120,
    val forceKeyframeAfterDroppedGops: Int = 1,
) {
    init {
        require(maxPublishLatencyUs > 0L) { "maxPublishLatencyUs must be positive" }
        require(maxQueuedFrames > 0) { "maxQueuedFrames must be positive" }
        require(forceKeyframeAfterDroppedGops > 0) { "forceKeyframeAfterDroppedGops must be positive" }
    }
}

/** Single inventory for Android media-pipeline tuning. */
internal object PipelinePolicies {
    val timeline = TimelinePolicy()
    val admission = AdmissionPolicy()
    val recovery = RecoveryPolicy()
    val render = RenderPolicy()
    val clock = ClockPolicy()
    val stall = StallPolicy()
    val switch = SwitchPolicy()
    val backpressure = BackpressurePolicy()
}
