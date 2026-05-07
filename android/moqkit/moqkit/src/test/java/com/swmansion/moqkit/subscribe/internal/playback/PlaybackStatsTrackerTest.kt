package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.moq.MoqFrame

class PlaybackStatsTrackerTest {
    @Test
    fun videoDecodeStatsAreNullBeforeSamples() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        val stats = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        )

        assertNull(stats.videoDecodeStats)
    }

    @Test
    fun videoDecodeStatsAccumulateMinMaxAverageAndLast() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        tracker.recordVideoDecodeTime("video/main", 12_000_000L, outputAtNs = 100_000_000L)
        tracker.recordVideoDecodeTime("video/main", 7_000_000L, outputAtNs = 133_000_000L)
        tracker.recordVideoDecodeTime("video/main", 20_000_000L, outputAtNs = 183_000_000L)

        val decode = tracker.snapshot(
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
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        tracker.recordVideoDecodeBufferSubmitted("video/main")
        tracker.recordVideoDecodeBufferSubmitted("video/main")

        val beforeOutput = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoDecodeStats!!

        assertEquals("video/main", beforeOutput.trackName)
        assertEquals(0L, beforeOutput.sampleCount)
        assertEquals(2, beforeOutput.inFlightBufferCount)
        assertNull(beforeOutput.minOutputIntervalMs)
        assertNull(beforeOutput.averageOutputIntervalMs)
        assertNull(beforeOutput.maxOutputIntervalMs)

        tracker.recordVideoDecodeTime("video/main", 6_000_000L, outputAtNs = 100_000_000L)

        val afterOutput = tracker.snapshot(
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
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")
        tracker.recordVideoDecodeTime("video/main", 12_000_000L)

        tracker.resetVideoDecodeStats("video/low")
        tracker.recordVideoDecodeTime("video/main", 20_000_000L)

        assertNull(
            tracker.snapshot(
                audioLatencyMs = null,
                videoLatencyMs = null,
            ).videoDecodeStats,
        )

        tracker.recordVideoDecodeTime("video/low", 5_000_000L)

        val decode = tracker.snapshot(
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

    @Test
    fun mediaFramesUpdateBitrateAndTimeToFirstFrame() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.markPlayStart()

        now += 100_000_000L
        tracker.onMediaFrame(testFrame(payloadSize = 100, timestampUs = 0u), MediaFrameKind.AUDIO)

        now += 200_000_000L
        tracker.onMediaFrame(testFrame(payloadSize = 100, timestampUs = 300_000u), MediaFrameKind.AUDIO)

        val stats = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        )

        assertEquals(100.0, stats.timeToFirstAudioFrameMs!!, 0.0001)
        assertEquals(8.0, stats.audioBitrateKbps!!, 0.0001)
    }

    @Test
    fun arrivalStatsSummarizeFrameCadence() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.onMediaFrame(testFrame(timestampUs = 0u), MediaFrameKind.VIDEO)
        now += 100_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 100_000u), MediaFrameKind.VIDEO)
        now += 100_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 200_000u), MediaFrameKind.VIDEO)

        val arrival = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoArrival!!

        assertEquals(15.0, arrival.receivedFramesPerSecond!!, 0.0001)
        assertEquals(100.0, arrival.averageInterarrivalMs!!, 0.0001)
        assertEquals(100.0, arrival.maxInterarrivalMs!!, 0.0001)
        assertEquals(0L, arrival.arrivalGapCount)
        assertEquals(0L, arrival.burstCount)
        assertEquals(0L, arrival.outOfOrderCount)
    }

    @Test
    fun arrivalStatsCountGapsBurstsAndOutOfOrderFrames() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.onMediaFrame(testFrame(timestampUs = 0u), MediaFrameKind.AUDIO)
        now += 100_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 100_000u), MediaFrameKind.AUDIO)
        now += 250_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 200_000u), MediaFrameKind.AUDIO)
        now += 10_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 300_000u), MediaFrameKind.AUDIO)
        now += 10_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 250_000u), MediaFrameKind.AUDIO)

        val arrival = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).audioArrival!!

        assertEquals(1L, arrival.arrivalGapCount)
        assertEquals(1L, arrival.burstCount)
        assertEquals(1L, arrival.outOfOrderCount)
        assertEquals(50.0, arrival.maxOutOfOrderDeltaMs!!, 0.0001)
    }

    @Test
    fun discontinuityResetsArrivalTimingBaseline() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.onMediaFrame(testFrame(timestampUs = 0u), MediaFrameKind.VIDEO)
        tracker.onFrameDiscontinuity(MediaFrameKind.VIDEO, gapUs = 700_000L)
        now += 700_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 700_000u, keyframe = true), MediaFrameKind.VIDEO)

        val arrival = tracker.snapshot(
            audioLatencyMs = null,
            videoLatencyMs = null,
        ).videoArrival!!

        assertEquals(1L, arrival.discontinuityCount)
        assertEquals(700.0, arrival.maxDiscontinuityGapMs!!, 0.0001)
        assertEquals(0L, arrival.arrivalGapCount)
        assertNull(arrival.averageInterarrivalMs)
    }
}

private fun testFrame(
    payloadSize: Int = 1,
    timestampUs: ULong,
    keyframe: Boolean = false,
): MoqFrame =
    MoqFrame(
        payload = ByteArray(payloadSize),
        timestampUs = timestampUs,
        keyframe = keyframe,
    )
