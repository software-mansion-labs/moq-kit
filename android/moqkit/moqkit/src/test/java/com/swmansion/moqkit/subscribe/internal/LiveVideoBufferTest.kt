package com.swmansion.moqkit.subscribe.internal

import com.swmansion.moqkit.subscribe.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LiveVideoBufferTest {
    @Test
    fun staleQueuedGopIsAbandonedAndWaitsForNextKeyframe() {
        val buffer = LiveVideoBuffer(maxDurationUs = 100_000L, maxBytes = 1_024L)

        buffer.offer(frame(timestampUs = 0L, keyframe = true))
        buffer.offer(frame(timestampUs = 150_000L, keyframe = false))

        assertEquals(MediaFrameEvent.Discontinuity.BacklogOverflow, buffer.poll())
        assertNull(buffer.poll())

        buffer.offer(frame(timestampUs = 160_000L, keyframe = false))
        assertNull(buffer.poll())

        val freshKeyframe = frame(timestampUs = 200_000L, keyframe = true)
        buffer.offer(freshKeyframe)
        assertEquals(MediaFrameEvent.Frame(freshKeyframe), buffer.poll())
    }

    @Test
    fun newerKeyframeReplacesOverflowedBacklogImmediately() {
        val buffer = LiveVideoBuffer(maxDurationUs = 100_000L, maxBytes = 1_024L)

        buffer.offer(frame(timestampUs = 0L, keyframe = true))
        val freshKeyframe = frame(timestampUs = 150_000L, keyframe = true)
        buffer.offer(freshKeyframe)

        assertEquals(MediaFrameEvent.Discontinuity.BacklogOverflow, buffer.poll())
        assertEquals(MediaFrameEvent.Frame(freshKeyframe), buffer.poll())
    }

    @Test
    fun byteCeilingCannotBeBypassedByFlatTimestamps() {
        val buffer = LiveVideoBuffer(maxDurationUs = 1_000_000L, maxBytes = 3L)

        buffer.offer(frame(timestampUs = 0L, keyframe = true, bytes = 2))
        buffer.offer(frame(timestampUs = 0L, keyframe = false, bytes = 2))

        assertEquals(MediaFrameEvent.Discontinuity.BacklogOverflow, buffer.poll())
        assertNull(buffer.poll())
    }

    private fun frame(timestampUs: Long, keyframe: Boolean, bytes: Int = 1): MediaFrame =
        MediaFrame(
            payload = ByteArray(bytes),
            timestampUs = timestampUs,
            keyframe = keyframe,
        )
}
