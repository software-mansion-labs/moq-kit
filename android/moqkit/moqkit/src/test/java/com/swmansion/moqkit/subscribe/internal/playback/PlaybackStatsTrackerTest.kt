package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.PlayerEventName
import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import com.swmansion.moqkit.subscribe.StallCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.moq.MoqFrame
import java.time.Duration

class PlaybackStatsTrackerTest {
    @Test
    fun droppedFrameCountersAcceptBatchedPipelineDrops() {
        val tracker = PlaybackStatsTracker()

        tracker.recordAudioFramesDropped(2)
        tracker.recordVideoFrameDropped(3)

        val stats = tracker.snapshot(audioLatency = null, videoLatency = null)
        assertEquals(2L, stats.audioFramesDropped)
        assertEquals(3L, stats.videoFramesDropped)
    }

    @Test
    fun videoDecodeStatsAreNullBeforeSamples() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        val stats = tracker.snapshot(audioLatency = null, videoLatency = null)

        assertNull(stats.videoDecodeStats)
    }

    @Test
    fun videoDecodeStatsAccumulateMinMaxAverageAndLast() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        tracker.recordVideoDecodeTime("video/main", 12_000_000L, outputAtNs = 100_000_000L)
        tracker.recordVideoDecodeTime("video/main", 7_000_000L, outputAtNs = 133_000_000L)
        tracker.recordVideoDecodeTime("video/main", 20_000_000L, outputAtNs = 183_000_000L)

        val decode = tracker.snapshot(audioLatency = null, videoLatency = null).videoDecodeStats!!

        assertEquals("video/main", decode.trackName)
        assertEquals(3L, decode.sampleCount)
        assertEquals(7L, decode.min.toMillis())
        assertEquals(20L, decode.max.toMillis())
        assertEquals(13L, decode.average.toMillis())
        assertEquals(20L, decode.last.toMillis())
        assertEquals(0, decode.inFlightBufferCount)
        assertEquals(33L, decode.minOutputInterval!!.toMillis())
        assertEquals(41L, decode.averageOutputInterval!!.toMillis())
        assertEquals(50L, decode.maxOutputInterval!!.toMillis())
    }

    @Test
    fun videoDecodeStatsTrackInFlightBuffersBeforeOutput() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")

        tracker.recordVideoDecodeBufferSubmitted("video/main")
        tracker.recordVideoDecodeBufferSubmitted("video/main")

        val beforeOutput = tracker.snapshot(audioLatency = null, videoLatency = null).videoDecodeStats!!

        assertEquals("video/main", beforeOutput.trackName)
        assertEquals(0L, beforeOutput.sampleCount)
        assertEquals(2, beforeOutput.inFlightBufferCount)
        assertNull(beforeOutput.minOutputInterval)
        assertNull(beforeOutput.averageOutputInterval)
        assertNull(beforeOutput.maxOutputInterval)

        tracker.recordVideoDecodeTime("video/main", 6_000_000L, outputAtNs = 100_000_000L)

        val afterOutput = tracker.snapshot(audioLatency = null, videoLatency = null).videoDecodeStats!!

        assertEquals(1L, afterOutput.sampleCount)
        assertEquals(1, afterOutput.inFlightBufferCount)
        assertNull(afterOutput.minOutputInterval)
        assertNull(afterOutput.averageOutputInterval)
        assertNull(afterOutput.maxOutputInterval)
    }

    @Test
    fun videoDecodeStatsResetOnTrackChange() {
        val tracker = PlaybackStatsTracker()
        tracker.resetVideoDecodeStats("video/main")
        tracker.recordVideoDecodeTime("video/main", 12_000_000L)

        tracker.resetVideoDecodeStats("video/low")
        tracker.recordVideoDecodeTime("video/main", 20_000_000L)

        assertNull(tracker.snapshot(audioLatency = null, videoLatency = null).videoDecodeStats)

        tracker.recordVideoDecodeTime("video/low", 5_000_000L)

        val decode = tracker.snapshot(audioLatency = null, videoLatency = null).videoDecodeStats!!

        assertEquals("video/low", decode.trackName)
        assertEquals(1L, decode.sampleCount)
        assertEquals(5L, decode.min.toMillis())
        assertEquals(5L, decode.max.toMillis())
        assertEquals(5L, decode.average.toMillis())
        assertEquals(5L, decode.last.toMillis())
    }

    @Test
    fun mediaFramesUpdateBitrateAndTrackReadyUpdatesTimeToFirstFrame() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.beginSession(MediaFrameKind.AUDIO)

        now += 100_000_000L
        tracker.emitTrackReady(
            TrackReadyContext(
                kind = MediaFrameKind.AUDIO,
                trackName = "audio/main",
                sourceTimestampUs = 0L,
                targetBuffering = Duration.ofMillis(100),
                trackEpoch = 1L,
                keyframe = false,
                payloadBytes = 100,
            ),
        )
        tracker.onMediaFrame(testFrame(payloadSize = 100, timestampUs = 0u), MediaFrameKind.AUDIO)

        now += 200_000_000L
        tracker.onMediaFrame(testFrame(payloadSize = 100, timestampUs = 300_000u), MediaFrameKind.AUDIO)

        val stats = tracker.snapshot(audioLatency = null, videoLatency = null)

        assertEquals(100L, stats.timeToFirst.audioFrame!!.toMillis())
        assertEquals(8.0, stats.audioBitrateKbps!!, 0.0001)
    }

    @Test
    fun trackPlayingUpdatesTimeToFirstPlayingAndStallStats() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.beginSession(MediaFrameKind.AUDIO)
        tracker.armAudioPlaybackStart(playbackStartContext(trackEpoch = 1L))

        now += 150_000_000L
        tracker.audioPlaybackStarted(timestampUs = 0L, hostTime = null)

        val stats = tracker.snapshot(audioLatency = null, videoLatency = null)
        assertEquals(150L, stats.timeToFirst.audioPlaying!!.toMillis())
        assertNotNull(stats.audioStalls)
        assertNull(stats.videoStalls)
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

        val arrival = tracker.snapshot(audioLatency = null, videoLatency = null).videoArrival!!

        assertEquals(15.0, arrival.receivedFramesPerSecond!!, 0.0001)
        assertEquals(100L, arrival.averageInterarrival!!.toMillis())
        assertEquals(100L, arrival.maxInterarrival!!.toMillis())
        assertEquals(0L, arrival.slowArrivalCount)
        assertEquals(0L, arrival.fastArrivalCount)
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

        val arrival = tracker.snapshot(audioLatency = null, videoLatency = null).audioArrival!!

        assertEquals(1L, arrival.slowArrivalCount)
        assertEquals(1L, arrival.fastArrivalCount)
        assertEquals(1L, arrival.outOfOrderCount)
        assertEquals(50L, arrival.maxOutOfOrderDelta!!.toMillis())
    }

    @Test
    fun discontinuityResetsArrivalTimingBaseline() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.onMediaFrame(testFrame(timestampUs = 0u), MediaFrameKind.VIDEO)
        tracker.onFrameDiscontinuity(MediaFrameKind.VIDEO, gapUs = 700_000L)
        now += 700_000_000L
        tracker.onMediaFrame(testFrame(timestampUs = 700_000u, keyframe = true), MediaFrameKind.VIDEO)

        val arrival = tracker.snapshot(audioLatency = null, videoLatency = null).videoArrival!!

        assertEquals(1L, arrival.discontinuityCount)
        assertEquals(700L, arrival.maxDiscontinuityGap!!.toMillis())
        assertEquals(0L, arrival.slowArrivalCount)
        assertNull(arrival.averageInterarrival)
    }

    @Test
    fun trackStartedResetsArrivalBaseline() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.onMediaTrackStarted(MediaFrameKind.VIDEO)
        tracker.onMediaFrame(testFrame(timestampUs = 1_000_000u), MediaFrameKind.VIDEO)
        now += 50_000_000L
        tracker.onMediaTrackStarted(MediaFrameKind.VIDEO)
        tracker.onMediaFrame(testFrame(timestampUs = 100_000u), MediaFrameKind.VIDEO)

        val arrival = tracker.snapshot(audioLatency = null, videoLatency = null).videoArrival!!

        assertEquals(0L, arrival.outOfOrderCount)
        assertNull(arrival.averageInterarrival)
    }

    @Test
    fun stallLifecycleDedupesAndReportsRebuffering() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.beginSession(MediaFrameKind.AUDIO)
        tracker.armAudioPlaybackStart(playbackStartContext(trackEpoch = 1L))
        tracker.audioPlaybackStarted(timestampUs = 0L, hostTime = null)
        tracker.noteStall(MediaFrameKind.AUDIO, stalled = true)
        tracker.noteStall(MediaFrameKind.AUDIO, stalled = true)
        now += 250_000_000L
        tracker.noteStall(MediaFrameKind.AUDIO, stalled = false)

        val stalls = tracker.snapshot(audioLatency = null, videoLatency = null).audioStalls!!
        assertEquals(1L, stalls.count)
        assertEquals(250L, stalls.totalDuration.toMillis())
        assertTrue(stalls.rebufferingRatio > 0.0)
    }

    @Test
    fun attributedPipelineStallsDriveLegacyStats() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })
        val context = PipelineContext("video/main", PipelineMediaKind.VIDEO, now)
        tracker.beginSession(MediaFrameKind.VIDEO)

        tracker.onPipelineEvent(PipelineEvent.StallStarted(context, StallCause.DECODE_STALL))
        now += 125_000_000L
        tracker.onPipelineEvent(
            PipelineEvent.StallEnded(context.copy(timestampNanos = now), StallCause.DECODE_STALL, 125),
        )

        val stalls = tracker.snapshot(audioLatency = null, videoLatency = null).videoStalls!!
        assertEquals(1L, stalls.count)
        assertEquals(125L, stalls.totalDuration.toMillis())
    }

    @Test
    fun closeOutInFlightStallsDoesNotCreateIdleStallStats() {
        val tracker = PlaybackStatsTracker()

        tracker.beginSession(MediaFrameKind.AUDIO)
        tracker.closeOutInFlightStalls()

        assertNull(tracker.snapshot(audioLatency = null, videoLatency = null).audioStalls)
    }

    @Test
    fun switchLifecycleAggregatesMilestones() {
        var now = 1_000_000_000L
        val tracker = PlaybackStatsTracker(clock = { now })

        tracker.beginSession(MediaFrameKind.VIDEO)
        tracker.emitSubscribeStart(MediaFrameKind.VIDEO, "video/high", trackEpoch = 2L)
        now += 100_000_000L
        tracker.emitTrackReady(
            TrackReadyContext(
                kind = MediaFrameKind.VIDEO,
                trackName = "video/high",
                sourceTimestampUs = 0L,
                targetBuffering = Duration.ofMillis(100),
                trackEpoch = 2L,
                keyframe = true,
                payloadBytes = 64,
            ),
        )
        now += 50_000_000L
        tracker.videoPlaybackStarted(
            context = playbackStartContext(
                kind = MediaFrameKind.VIDEO,
                trackName = "video/high",
                trackEpoch = 2L,
            ),
            presentationTimeUs = 0L,
            clockTimeUs = 0L,
            buffer = Duration.ZERO,
        )
        now += 25_000_000L
        tracker.emitTrackSwitch(MediaFrameKind.VIDEO, "video/high", trackEpoch = 2L)

        val switches = tracker.snapshot(audioLatency = null, videoLatency = null).videoSwitches!!
        val latest = switches.latest!!
        assertEquals(1L, switches.requestedCount)
        assertEquals(1L, switches.completedCount)
        assertEquals("video/high", latest.trackName)
        assertTrue(latest.isCompleted)
        assertEquals(100L, latest.switchToReady!!.toMillis())
        assertEquals(50L, latest.readyToPlaying!!.toMillis())
        assertEquals(175L, latest.switchToActive!!.toMillis())
    }

    @Test
    fun failedSwitchRecordsErrorWithoutCompletion() {
        val tracker = PlaybackStatsTracker()

        tracker.beginSession(MediaFrameKind.AUDIO)
        tracker.emitSubscribeStart(MediaFrameKind.AUDIO, "audio/alt", trackEpoch = 2L)
        tracker.emitSubscribeError(
            MediaFrameKind.AUDIO,
            "audio/alt",
            "subscribe failed",
            trackEpoch = 2L,
        )

        val switches = tracker.snapshot(audioLatency = null, videoLatency = null).audioSwitches!!
        val latest = switches.latest!!
        assertEquals(1L, switches.requestedCount)
        assertEquals(0L, switches.completedCount)
        assertFalse(latest.isCompleted)
        assertEquals("subscribe failed", latest.errorMessage)
    }

    @Test
    fun playerEventNamesMatchWireValues() {
        assertEquals("track.ready", PlayerEventName.TRACK_READY.value)
        assertEquals("track.switch", PlayerEventName.TRACK_SWITCH.value)
        assertEquals("track.playing", PlayerEventName.TRACK_PLAYING.value)
        assertEquals("decode.error", PlayerEventName.DECODE_ERROR.value)
    }
}

private fun playbackStartContext(
    kind: MediaFrameKind = MediaFrameKind.AUDIO,
    trackName: String = "audio/main",
    trackEpoch: Long,
): PlaybackStartContext =
    PlaybackStartContext(
        kind = kind,
        trackName = trackName,
        sourceTimestampUs = 0L,
        targetBuffering = Duration.ofMillis(100),
        trackEpoch = trackEpoch,
    )

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
