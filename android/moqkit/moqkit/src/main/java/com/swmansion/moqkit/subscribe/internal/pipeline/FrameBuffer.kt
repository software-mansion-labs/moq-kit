package com.swmansion.moqkit.subscribe.internal.pipeline

internal enum class AdmissionRejectReason {
    WAITING_FOR_KEYFRAME,
    FRAME_TOO_LARGE,
    OLD_EPOCH,
    UNEXPECTED_EPOCH,
    DUPLICATE,
}

internal sealed interface AdmissionEffect {
    data class Admitted(val frame: TimedFrame) : AdmissionEffect

    data class Rejected(
        val frame: TimedFrame,
        val reason: AdmissionRejectReason,
    ) : AdmissionEffect

    data class EvictedGop(
        val groupSequence: Long?,
        val count: Int,
        val bytes: Long,
    ) : AdmissionEffect
}

/**
 * The single compressed-frame buffer before decode. It owns capacity admission,
 * whole-GOP eviction, decode ordering, and keyframe gating after reset.
 */
internal class FrameBuffer(
    private val policy: AdmissionPolicy,
) {
    private val frames = mutableListOf<TimedFrame>()
    private var bytes: Long = 0L
    private var keyframeAccepted = !policy.requireKeyframeAfterReset

    var currentEpoch: Long? = null
        private set

    fun offer(frame: TimedFrame): List<AdmissionEffect> {
        if (frame.sizeBytes.toLong() > policy.maxBytes) {
            return rejected(frame, AdmissionRejectReason.FRAME_TOO_LARGE)
        }

        val epoch = currentEpoch
        when {
            epoch == null -> currentEpoch = frame.epoch
            frame.epoch < epoch -> return rejected(frame, AdmissionRejectReason.OLD_EPOCH)
            frame.epoch > epoch -> return rejected(frame, AdmissionRejectReason.UNEXPECTED_EPOCH)
        }

        if (!keyframeAccepted && !frame.keyframe) {
            return rejected(frame, AdmissionRejectReason.WAITING_FOR_KEYFRAME)
        }
        if (isDuplicate(frame)) {
            return rejected(frame, AdmissionRejectReason.DUPLICATE)
        }

        if (frame.keyframe) keyframeAccepted = true
        insertSorted(frame)
        bytes += frame.sizeBytes

        val effects = mutableListOf<AdmissionEffect>(AdmissionEffect.Admitted(frame))
        while (isOverflowing() && frames.isNotEmpty()) {
            effects += evictOldestGop()
        }
        return effects
    }

    @Suppress("UNUSED_PARAMETER")
    fun pollPlayable(nowUs: Long): TimedFrame? {
        if (!keyframeAccepted || frames.isEmpty()) return null
        val frame = frames.removeAt(0)
        bytes -= frame.sizeBytes
        return frame
    }

    fun reset(epoch: Long): Int {
        require(epoch >= 0L) { "epoch must be non-negative" }
        val flushed = frames.size
        frames.clear()
        bytes = 0L
        currentEpoch = epoch
        keyframeAccepted = !policy.requireKeyframeAfterReset
        return flushed
    }

    fun depth(): BufferDepth = BufferDepth(
        frames = frames.size,
        bytes = bytes,
        durationUs = durationUs(),
    )

    private fun rejected(frame: TimedFrame, reason: AdmissionRejectReason): List<AdmissionEffect> =
        listOf(AdmissionEffect.Rejected(frame, reason))

    private fun insertSorted(frame: TimedFrame) {
        val index = frames.binarySearch { existing -> compareFrames(existing, frame) }
        frames.add(if (index >= 0) index + 1 else -index - 1, frame)
    }

    private fun compareFrames(left: TimedFrame, right: TimedFrame): Int {
        val timestampComparison = left.timestampUs.compareTo(right.timestampUs)
        if (timestampComparison != 0) return timestampComparison
        return (left.frameIndex ?: Int.MAX_VALUE).compareTo(right.frameIndex ?: Int.MAX_VALUE)
    }

    private fun isDuplicate(frame: TimedFrame): Boolean = frames.any { existing ->
        existing.epoch == frame.epoch &&
            existing.timestampUs == frame.timestampUs &&
            when {
                existing.groupSequence != null && frame.groupSequence != null ->
                    existing.groupSequence == frame.groupSequence && existing.frameIndex == frame.frameIndex
                else -> existing.keyframe == frame.keyframe
            }
    }

    private fun isOverflowing(): Boolean =
        bytes > policy.maxBytes ||
            frames.size > policy.maxFrames ||
            durationUs() > policy.maxDurationUs

    private fun durationUs(): Long {
        if (frames.size < 2) return 0L
        val first = frames.first().timestampUs
        val last = frames.last().timestampUs
        return if (last <= first) 0L else last - first
    }

    private fun evictOldestGop(): AdmissionEffect.EvictedGop {
        val first = frames.first()
        val groupSequence = first.groupSequence
        val evictionCount = if (!policy.evictWholeGops) {
            1
        } else if (groupSequence != null) {
            frames.takeWhile { it.groupSequence == groupSequence }.size.coerceAtLeast(1)
        } else {
            val nextKeyframe = frames.indexOfFirstFrom(startIndex = 1) { it.keyframe }
            if (nextKeyframe < 0) frames.size else nextKeyframe
        }

        var evictedBytes = 0L
        repeat(evictionCount) {
            evictedBytes += frames.removeAt(0).sizeBytes
        }
        bytes -= evictedBytes
        return AdmissionEffect.EvictedGop(
            groupSequence = groupSequence,
            count = evictionCount,
            bytes = evictedBytes,
        )
    }

    private inline fun <T> List<T>.indexOfFirstFrom(startIndex: Int, predicate: (T) -> Boolean): Int {
        for (index in startIndex until size) {
            if (predicate(this[index])) return index
        }
        return -1
    }
}
