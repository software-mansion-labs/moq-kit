package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameBufferTest {
    @Test
    fun requiresKeyframeAfterResetAndPollsInDecodeOrder() {
        val buffer = FrameBuffer(
            AdmissionPolicy(maxBytes = 100, maxFrames = 10, maxDurationUs = 10_000),
        )
        buffer.reset(epoch = 4)

        val rejected = buffer.offer(frame(200, keyframe = false, epoch = 4, group = 2))
        buffer.offer(frame(100, keyframe = true, epoch = 4, group = 1))
        buffer.offer(frame(150, keyframe = false, epoch = 4, group = 1))

        assertEquals(
            AdmissionRejectReason.WAITING_FOR_KEYFRAME,
            (rejected.single() as AdmissionEffect.Rejected).reason,
        )
        assertEquals(100L, buffer.pollPlayable(nowUs = 0)?.timestampUs)
        assertEquals(150L, buffer.pollPlayable(nowUs = 0)?.timestampUs)
        assertNull(buffer.pollPlayable(nowUs = 0))
    }

    @Test
    fun overflowEvictsTheOldestWholeGop() {
        val buffer = FrameBuffer(
            AdmissionPolicy(
                maxBytes = 100,
                maxFrames = 3,
                maxDurationUs = 10_000,
                evictWholeGops = true,
            ),
        )
        buffer.offer(frame(100, keyframe = true, epoch = 1, group = 10, bytes = 10))
        buffer.offer(frame(110, keyframe = false, epoch = 1, group = 10, bytes = 10))
        buffer.offer(frame(200, keyframe = true, epoch = 1, group = 11, bytes = 10))

        val effects = buffer.offer(frame(210, keyframe = false, epoch = 1, group = 11, bytes = 10))

        val eviction = effects.filterIsInstance<AdmissionEffect.EvictedGop>().single()
        assertEquals(10L, eviction.groupSequence)
        assertEquals(2, eviction.count)
        assertEquals(2, buffer.depth().frames)
        assertEquals(200L, buffer.pollPlayable(nowUs = 0)?.timestampUs)
    }

    @Test
    fun durationOverflowAlsoUsesWholeGopEviction() {
        val buffer = FrameBuffer(
            AdmissionPolicy(maxBytes = 1_000, maxFrames = 10, maxDurationUs = 50),
        )
        buffer.offer(frame(100, keyframe = true, epoch = 1, group = 1))
        buffer.offer(frame(120, keyframe = false, epoch = 1, group = 1))

        val effects = buffer.offer(frame(200, keyframe = true, epoch = 1, group = 2))

        assertTrue(effects.any { it is AdmissionEffect.EvictedGop && it.groupSequence == 1L })
        assertEquals(1, buffer.depth().frames)
    }

    @Test
    fun resetReportsExactlyHowManyFramesWereFlushed() {
        val buffer = FrameBuffer(
            AdmissionPolicy(maxBytes = 100, maxFrames = 10, maxDurationUs = 1_000),
        )
        buffer.offer(frame(100, keyframe = true, epoch = 1, group = 1))
        buffer.offer(frame(110, keyframe = false, epoch = 1, group = 1))

        assertEquals(2, buffer.reset(epoch = 2))
        assertEquals(BufferDepth.Empty, buffer.depth())
        assertEquals(2L, buffer.currentEpoch)
    }

    @Test
    fun oversizedAndOldEpochFramesAreRejected() {
        val buffer = FrameBuffer(
            AdmissionPolicy(maxBytes = 5, maxFrames = 10, maxDurationUs = 1_000),
        )
        buffer.reset(epoch = 2)

        val oversized = buffer.offer(frame(100, true, epoch = 2, group = 1, bytes = 6))
        val old = buffer.offer(frame(100, true, epoch = 1, group = 1, bytes = 1))

        assertEquals(AdmissionRejectReason.FRAME_TOO_LARGE, (oversized.single() as AdmissionEffect.Rejected).reason)
        assertEquals(AdmissionRejectReason.OLD_EPOCH, (old.single() as AdmissionEffect.Rejected).reason)
    }

    @Test
    fun supportsNonDestructiveInspectionAndExplicitDiscardForSwitching() {
        val buffer = FrameBuffer(
            AdmissionPolicy(maxBytes = 100, maxFrames = 10, maxDurationUs = 1_000),
        )
        buffer.offer(frame(100, true, epoch = 1, group = 1))
        buffer.offer(frame(110, false, epoch = 1, group = 1))

        assertEquals(100L, buffer.peekFront()?.timestampUs)
        assertEquals(100L, buffer.firstWhere { it.keyframe }?.timestampUs)
        assertEquals(100L, buffer.removeFront()?.timestampUs)
        assertEquals(110L, buffer.peekFront()?.timestampUs)
    }

    @Test
    fun singleFrameEvictionRearmsKeyframeGateWhenAnchorIsLost() {
        val buffer = FrameBuffer(
            AdmissionPolicy(
                maxBytes = 100,
                maxFrames = 2,
                maxDurationUs = 1_000,
                evictWholeGops = false,
            ),
        )
        buffer.offer(frame(100, true, epoch = 1, group = 1))
        buffer.offer(frame(110, false, epoch = 1, group = 1))
        buffer.offer(frame(120, false, epoch = 1, group = 1))

        assertNull(buffer.pollPlayable(nowUs = 0L))
        assertEquals(
            AdmissionRejectReason.WAITING_FOR_KEYFRAME,
            (buffer.offer(frame(130, false, epoch = 1, group = 1)).single() as AdmissionEffect.Rejected).reason,
        )
    }

    private fun frame(
        timestampUs: Long,
        keyframe: Boolean,
        epoch: Long,
        group: Long,
        bytes: Int = 1,
    ) = TimedFrame(
        mediaFrame = MediaFrame(ByteArray(bytes), timestampUs, keyframe),
        groupSequence = group,
        frameIndex = 0,
        epoch = epoch,
    )
}
