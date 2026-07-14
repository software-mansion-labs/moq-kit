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
        rejectionReason(frame)?.let { return rejected(frame, it) }
        if (currentEpoch == null) currentEpoch = frame.epoch

        val effects = mutableListOf<AdmissionEffect>()
        if (frame.keyframe && !keyframeAccepted && frames.isNotEmpty()) {
            effects += evictAllBufferedFrames()
        }
        if (frame.keyframe) keyframeAccepted = true
        insertSorted(frame)
        bytes += frame.sizeBytes

        effects += AdmissionEffect.Admitted(frame)
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

    fun rejectionReason(frame: TimedFrame): AdmissionRejectReason? {
        if (frame.sizeBytes.toLong() > policy.maxBytes) return AdmissionRejectReason.FRAME_TOO_LARGE
        val epoch = currentEpoch
        if (epoch != null && frame.epoch < epoch) return AdmissionRejectReason.OLD_EPOCH
        if (epoch != null && frame.epoch > epoch) return AdmissionRejectReason.UNEXPECTED_EPOCH
        if (!keyframeAccepted && !frame.keyframe) return AdmissionRejectReason.WAITING_FOR_KEYFRAME
        if (isDuplicate(frame)) return AdmissionRejectReason.DUPLICATE
        return null
    }

    fun peekFront(): TimedFrame? = frames.firstOrNull()

    fun peekAt(index: Int): TimedFrame? = frames.getOrNull(index)

    fun firstWhere(predicate: (TimedFrame) -> Boolean): TimedFrame? = frames.firstOrNull(predicate)

    fun removeFront(): TimedFrame? {
        if (frames.isEmpty()) return null
        val removed = frames.removeAt(0)
        bytes -= removed.sizeBytes
        if (removed.keyframe && frames.firstOrNull()?.keyframe != true) {
            keyframeAccepted = false
        }
        return removed
    }

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
            val removed = frames.removeAt(0)
            evictedBytes += removed.sizeBytes
        }
        bytes -= evictedBytes
        if (policy.requireKeyframeAfterReset) {
            keyframeAccepted = frames.firstOrNull()?.keyframe == true
        }
        return AdmissionEffect.EvictedGop(
            groupSequence = groupSequence,
            count = evictionCount,
            bytes = evictedBytes,
        )
    }

    private fun evictAllBufferedFrames(): AdmissionEffect.EvictedGop {
        val count = frames.size
        val evictedBytes = bytes
        val groupSequence = frames.firstOrNull()?.groupSequence
        frames.clear()
        bytes = 0L
        return AdmissionEffect.EvictedGop(groupSequence, count, evictedBytes)
    }

    private inline fun <T> List<T>.indexOfFirstFrom(startIndex: Int, predicate: (T) -> Boolean): Int {
        for (index in startIndex until size) {
            if (predicate(this[index])) return index
        }
        return -1
    }
}
