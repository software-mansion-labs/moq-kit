package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackMetricsAccumulatorTest {
    @Test
    fun videoDecodeStatsAreNullBeforeSamples() {
        val accumulator = PlaybackMetricsAccumulator()
        accumulator.resetVideoDecodeStats("video/main")

        val stats = accumulator.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        )

        assertNull(stats.videoDecodeStats)
    }

    @Test
    fun videoDecodeStatsAccumulateMinMaxAverageAndLast() {
        val accumulator = PlaybackMetricsAccumulator()
        accumulator.resetVideoDecodeStats("video/main")

        accumulator.recordVideoDecodeTime("video/main", 12_000_000L, outputAtNs = 100_000_000L)
        accumulator.recordVideoDecodeTime("video/main", 7_000_000L, outputAtNs = 133_000_000L)
        accumulator.recordVideoDecodeTime("video/main", 20_000_000L, outputAtNs = 183_000_000L)

        val decode = accumulator.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoDecodeStats!!

        assertEquals("video/main", decode.trackName)
        assertEquals(3L, decode.sampleCount)
        assertEquals(7.0, decode.minMs, 0.0001)
        assertEquals(20.0, decode.maxMs, 0.0001)
        assertEquals(13.0, decode.averageMs, 0.0001)
        assertEquals(20.0, decode.lastMs, 0.0001)
        assertEquals(0, decode.inFlightBufferCount)
        assertEquals(33.0, decode.minOutputIntervalMs!!, 0.0001)
        assertEquals(41.5, decode.averageOutputIntervalMs!!, 0.0001)
        assertEquals(50.0, decode.maxOutputIntervalMs!!, 0.0001)
    }

    @Test
    fun videoDecodeStatsTrackInFlightBuffersBeforeOutput() {
        val accumulator = PlaybackMetricsAccumulator()
        accumulator.resetVideoDecodeStats("video/main")

        accumulator.recordVideoDecodeBufferSubmitted("video/main")
        accumulator.recordVideoDecodeBufferSubmitted("video/main")

        val beforeOutput = accumulator.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoDecodeStats!!

        assertEquals("video/main", beforeOutput.trackName)
        assertEquals(0L, beforeOutput.sampleCount)
        assertEquals(2, beforeOutput.inFlightBufferCount)
        assertNull(beforeOutput.minOutputIntervalMs)
        assertNull(beforeOutput.averageOutputIntervalMs)
        assertNull(beforeOutput.maxOutputIntervalMs)

        accumulator.recordVideoDecodeTime("video/main", 6_000_000L, outputAtNs = 100_000_000L)

        val afterOutput = accumulator.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoDecodeStats!!

        assertEquals(1L, afterOutput.sampleCount)
        assertEquals(1, afterOutput.inFlightBufferCount)
        assertNull(afterOutput.minOutputIntervalMs)
        assertNull(afterOutput.averageOutputIntervalMs)
        assertNull(afterOutput.maxOutputIntervalMs)
    }

    @Test
    fun videoDecodeStatsResetOnTrackChange() {
        val accumulator = PlaybackMetricsAccumulator()
        accumulator.resetVideoDecodeStats("video/main")
        accumulator.recordVideoDecodeTime("video/main", 12_000_000L)

        accumulator.resetVideoDecodeStats("video/low")
        accumulator.recordVideoDecodeTime("video/main", 20_000_000L)

        assertNull(
            accumulator.snapshot(
                audioLatencyMs = null,
                videoLatencyMs = null,
            ).videoDecodeStats,
        )

        accumulator.recordVideoDecodeTime("video/low", 5_000_000L)

        val decode = accumulator.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoDecodeStats!!

        assertEquals("video/low", decode.trackName)
        assertEquals(1L, decode.sampleCount)
        assertEquals(5.0, decode.minMs, 0.0001)
        assertEquals(5.0, decode.maxMs, 0.0001)
        assertEquals(5.0, decode.averageMs, 0.0001)
        assertEquals(5.0, decode.lastMs, 0.0001)
    }
}
