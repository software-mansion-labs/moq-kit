package com.swmansion.moqkit.subscribe.internal

import com.swmansion.moqkit.subscribe.MediaFrame
import java.util.TreeMap

/**
 * GOP-aware queue used by live Player video subscriptions.
 *
 * If the consumer falls beyond its latency or memory budget, the current GOP is no longer
 * useful: arbitrary delta-frame eviction would leave the decoder without references. The queue
 * therefore emits a discontinuity and waits for the next keyframe.
 */
internal class LiveVideoBuffer(
    private val maxDurationUs: Long,
    private val maxBytes: Long,
) {
    private val events = ArrayDeque<MediaFrameEvent>()
    private val timestampCounts = TreeMap<Long, Int>()
    private var queuedBytes = 0L
    private var waitingForKeyframe = true

    fun offer(frame: MediaFrame) {
        if (waitingForKeyframe) {
            if (!frame.keyframe) return
            waitingForKeyframe = false
        }

        enqueue(frame)

        if (!isOverBudget()) return

        if (frame.keyframe && frame.payload.size.toLong() <= maxBytes.coerceAtLeast(1L)) {
            clearQueue()
            events.addLast(MediaFrameEvent.Discontinuity.BacklogOverflow)
            enqueue(frame)
            waitingForKeyframe = false
        } else {
            clearQueue()
            events.addLast(MediaFrameEvent.Discontinuity.BacklogOverflow)
            waitingForKeyframe = true
        }
    }

    fun poll(): MediaFrameEvent? {
        val event = events.removeFirstOrNull() ?: return null
        if (event is MediaFrameEvent.Frame) {
            queuedBytes -= event.frame.payload.size
            removeTimestamp(event.frame.timestampUs)
        }
        return event
    }

    fun clear() {
        clearQueue()
        waitingForKeyframe = true
    }

    private fun isOverBudget(): Boolean {
        if (queuedBytes > maxBytes.coerceAtLeast(1L)) return true
        if (timestampCounts.size < 2) return false
        val durationUs = try {
            Math.subtractExact(timestampCounts.lastKey(), timestampCounts.firstKey())
        } catch (_: ArithmeticException) {
            return true
        }
        return durationUs > maxDurationUs.coerceAtLeast(0L)
    }

    private fun enqueue(frame: MediaFrame) {
        events.addLast(MediaFrameEvent.Frame(frame))
        queuedBytes += frame.payload.size
        timestampCounts.merge(frame.timestampUs, 1, Int::plus)
    }

    private fun removeTimestamp(timestampUs: Long) {
        val count = timestampCounts[timestampUs] ?: return
        if (count == 1) {
            timestampCounts.remove(timestampUs)
        } else {
            timestampCounts[timestampUs] = count - 1
        }
    }

    private fun clearQueue() {
        events.clear()
        timestampCounts.clear()
        queuedBytes = 0L
    }
}
