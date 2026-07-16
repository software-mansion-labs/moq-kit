package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PcmRingTest {
    private val policy = PcmRingPolicy(
        maxBytes = 8,
        maxFrames = 4,
        maxDurationUs = 4_000,
    )

    @Test
    fun waitsForTargetCapacityBeforeReading() {
        val ring = PcmRing(sampleRate = 1_000, channels = 1, policy)
        val output = ShortArray(4)

        ring.write(timestampUs = 0, samples = shortArrayOf(1, 2), frameCount = 2)
        assertEquals(0, ring.read(output, 4))

        ring.write(timestampUs = 2_000, samples = shortArrayOf(3, 4), frameCount = 2)
        assertEquals(4, ring.read(output, 4))
        assertArrayEquals(shortArrayOf(1, 2, 3, 4), output)
    }

    @Test
    fun reportsOldInputWithoutMutatingReadableSamples() {
        val ring = PcmRing(sampleRate = 1_000, channels = 1, policy)
        ring.write(0, shortArrayOf(1, 2, 3, 4), 4)
        ring.read(ShortArray(2), 2)

        val result = ring.write(0, shortArrayOf(9), 1)

        assertEquals(PcmRing.WriteResult(acceptedFrames = 0, rejectedOldFrames = 1), result)
        val output = ShortArray(2)
        assertEquals(2, ring.read(output, 2))
        assertArrayEquals(shortArrayOf(3, 4), output)
    }

    @Test
    fun fillsTimestampGapWithSilence() {
        val ring = PcmRing(sampleRate = 1_000, channels = 1, policy)
        ring.write(0, shortArrayOf(1), 1)

        val result = ring.write(3_000, shortArrayOf(4), 1)

        assertEquals(2, result.silenceFrames)
        val output = ShortArray(4)
        assertEquals(4, ring.read(output, 4))
        assertArrayEquals(shortArrayOf(1, 0, 0, 4), output)
    }

    @Test
    fun overflowEvictsOldestFramesAndReportsThem() {
        val ring = PcmRing(sampleRate = 1_000, channels = 1, policy)
        ring.write(0, shortArrayOf(1, 2, 3, 4), 4)

        val result = ring.write(4_000, shortArrayOf(5, 6), 2)

        assertEquals(2, result.evictedFrames)
        val output = ShortArray(4)
        assertEquals(4, ring.read(output, 4))
        assertArrayEquals(shortArrayOf(3, 4, 5, 6), output)
    }

    @Test
    fun timestampSurvivesLargeAbsolutePts() {
        val largePolicy = policy.copy(
            maxBytes = 38_400,
            maxFrames = 9_600,
            maxDurationUs = 200_000,
        )
        val ring = PcmRing(sampleRate = 48_000, channels = 2, largePolicy)
        val ptsUs = 2_544_371_617_638L

        ring.write(ptsUs, ShortArray(1_920), frameCount = 960)

        assertEquals(ptsUs.toDouble(), ring.timestampUs.toDouble(), 1_000.0)
    }

    @Test
    fun resizePreservesNewestSamplesAndReentersBuffering() {
        val ring = PcmRing(sampleRate = 1_000, channels = 1, policy)
        ring.write(1_000, shortArrayOf(1, 2, 3, 4), 4)

        ring.resize(policy.copy(maxBytes = 6, maxFrames = 3, maxDurationUs = 3_000))

        assertEquals(3, ring.capacity)
        assertEquals(0, ring.read(ShortArray(3), 3))
        ring.write(5_000, shortArrayOf(5), 1)
        val output = ShortArray(3)
        assertEquals(3, ring.read(output, 3))
        assertArrayEquals(shortArrayOf(3, 4, 5), output)
    }
}
