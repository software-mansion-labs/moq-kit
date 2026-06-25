package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.moq.MoqFrame

class MediaLiveEdgeTest {
    @Test
    fun tracksMaxTimestampToWallClockOffset() {
        var wallClock = 1_000L
        val edge = MediaLiveEdge { wallClock }

        edge.recordTimestamp(5_000L)
        assertEquals(5_000L, edge.estimatedLivePTS())

        wallClock = 2_000L
        assertEquals(6_000L, edge.estimatedLivePTS())

        edge.recordTimestamp(5_500L)
        wallClock = 3_000L
        assertEquals(7_000L, edge.estimatedLivePTS())
    }

    @Test
    fun resetClearsEstimatedTime() {
        var wallClock = 1_000L
        val edge = MediaLiveEdge { wallClock }

        edge.recordTimestamp(5_000L)
        edge.reset()

        assertNull(edge.estimatedLivePTS())
    }
}

class MediaTimestampAlignerTest {
    @Test
    fun offsetRequiresAudioAndVideoLiveEdges() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        assertNull(aligner.videoOffset(threshold = 2_000L))

        aligner.audioLiveEdge.recordTimestamp(10_000L)
        assertNull(aligner.videoOffset(threshold = 2_000L))

        aligner.videoLiveEdge.recordTimestamp(4_000L)
        assertEquals(6_000L, aligner.videoOffset(threshold = 2_000L))
    }

    @Test
    fun alignedTimestampsReturnNoOpCorrection() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        aligner.audioLiveEdge.recordTimestamp(10_000L)
        aligner.videoLiveEdge.recordTimestamp(9_000L)

        assertNull(aligner.videoOffset(threshold = 2_000L))
        assertEquals(9_000L, aligner.audioTime(videoTime = 9_000L, threshold = 2_000L))
        assertEquals(10_000L, aligner.videoTime(audioTime = 10_000L, threshold = 2_000L))
    }

    @Test
    fun driftedVideoTimestampsMapIntoAudioTime() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        aligner.audioLiveEdge.recordTimestamp(10_000L)
        aligner.videoLiveEdge.recordTimestamp(4_000L)

        assertEquals(6_000L, aligner.videoOffset(threshold = 2_000L))
        assertEquals(10_000L, aligner.audioTime(videoTime = 4_000L, threshold = 2_000L))
        assertEquals(4_000L, aligner.videoTime(audioTime = 10_000L, threshold = 2_000L))
    }

    @Test
    fun driftedAudioTimestampsMapBackIntoVideoTime() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        aligner.audioLiveEdge.recordTimestamp(4_000L)
        aligner.videoLiveEdge.recordTimestamp(10_000L)

        assertEquals(-6_000L, aligner.videoOffset(threshold = 2_000L))
        assertEquals(4_000L, aligner.audioTime(videoTime = 10_000L, threshold = 2_000L))
        assertEquals(10_000L, aligner.videoTime(audioTime = 4_000L, threshold = 2_000L))
    }

    @Test
    fun observerRecordsLiveEdgeForFrameKind() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        aligner.onMediaFrame(testFrame(timestampUs = 10_000u), MediaFrameKind.AUDIO)

        assertEquals(10_000L, aligner.audioLiveEdge.estimatedLivePTS())
        assertNull(aligner.videoLiveEdge.estimatedLivePTS())

        aligner.onMediaFrame(testFrame(timestampUs = 7_000u), MediaFrameKind.VIDEO)

        assertEquals(7_000L, aligner.videoLiveEdge.estimatedLivePTS())
    }

    @Test
    fun observerDiscontinuityResetsOnlyAffectedLiveEdge() {
        var wallClock = 1_000L
        val aligner = MediaTimestampAligner(
            audioLiveEdge = MediaLiveEdge { wallClock },
            videoLiveEdge = MediaLiveEdge { wallClock },
        )

        aligner.onMediaFrame(testFrame(timestampUs = 10_000u), MediaFrameKind.AUDIO)
        aligner.onMediaFrame(testFrame(timestampUs = 7_000u), MediaFrameKind.VIDEO)

        aligner.onFrameDiscontinuity(MediaFrameKind.VIDEO, gapUs = 700_000L)

        assertEquals(10_000L, aligner.audioLiveEdge.estimatedLivePTS())
        assertNull(aligner.videoLiveEdge.estimatedLivePTS())
    }
}

class MediaClockTest {
    @Test
    fun audioDrivenClockCurrentTimeCanBeSetAndReset() {
        val clock = AudioDrivenClock()

        clock.setCurrentTimeUs(19_000L)
        assertEquals(19_000L, clock.currentTimeUs)

        clock.reset()
        assertEquals(0L, clock.currentTimeUs)
    }

    @Test
    fun videoDrivenClockAdvancesOnlyWhenRunning() {
        var wallClock = 1_000L
        val clock = VideoDrivenClock { wallClock }

        clock.setRate(1.0, timeUs = 10_000L)
        wallClock = 1_500L
        assertEquals(10_500L, clock.currentTimeUs)

        clock.setRate(0.0)
        wallClock = 3_000L
        assertEquals(10_500L, clock.currentTimeUs)
    }
}

class JitterBufferTest {
    @Test
    fun targetPlaybackPtsUsesEstimatedLiveEdgeMinusTargetBuffering() {
        var wallClock = 1_000L
        val buffer = JitterBuffer<Int>(
            targetBufferingUs = 1_000L,
            wallClockUs = { wallClock },
        )

        buffer.insert(item = 1, timestampUs = 10_000L)
        wallClock = 2_000L
        buffer.insert(item = 2, timestampUs = 11_000L)
        wallClock = 2_500L

        assertEquals(JitterBuffer.State.PLAYING, buffer.state)
        assertEquals(11_500L, buffer.estimatedLivePTS())
        assertEquals(10_500L, buffer.targetPlaybackPTS())
        assertEquals(1_000L, buffer.frontFrameIntervalUs)
    }

    @Test
    fun updatingTargetBufferingCanStartBufferedVideo() {
        var wallClock = 0L
        val buffer = JitterBuffer<Int>(
            targetBufferingUs = 2_000L,
            wallClockUs = { wallClock },
        )

        buffer.insert(item = 1, timestampUs = 1_000L)
        wallClock = 100L
        buffer.insert(item = 2, timestampUs = 2_000L)

        assertEquals(JitterBuffer.State.BUFFERING, buffer.state)
        assertEquals(true, buffer.updateTargetBuffering(1_000L))
        assertEquals(JitterBuffer.State.PLAYING, buffer.state)
    }

    @Test
    fun updatingTargetBufferingKeepsPlayingVideoPlayable() {
        val buffer = JitterBuffer<Int>(targetBufferingUs = 1_000L)

        buffer.insert(item = 1, timestampUs = 1_000L)
        buffer.insert(item = 2, timestampUs = 2_000L)

        assertEquals(JitterBuffer.State.PLAYING, buffer.state)
        assertEquals(false, buffer.updateTargetBuffering(5_000L))
        assertEquals(JitterBuffer.State.PLAYING, buffer.state)
    }

    /**
     * Playability is decided against the video live-edge target
     * (`estimatedLivePTS - targetBufferingUs`), matching iOS `dequeue()`. The boundary is
     * inclusive at exactly `targetPlaybackPTS` and exclusive one microsecond below it.
     */
    @Test
    fun dequeuePlayabilityMatchesTargetPlaybackPtsBoundary() {
        var wallClock = 1_000L
        val buffer = JitterBuffer<Int>(
            targetBufferingUs = 1_000L,
            wallClockUs = { wallClock },
        )

        buffer.insert(item = 1, timestampUs = 10_000L)
        wallClock = 2_000L
        buffer.insert(item = 2, timestampUs = 11_000L)
        // Both frames carry offset 9_000, so maxOffset = 9_000.
        // targetPlaybackPts = wallClock + 9_000 - 1_000 = wallClock + 8_000.
        assertEquals(JitterBuffer.State.PLAYING, buffer.state)

        // wallClock = 2_000 => targetPlaybackPts = 10_000; front ts 10_000 is exactly playable.
        assertEquals(10_000L, buffer.targetPlaybackPTS())
        val (first, firstPlayable) = buffer.dequeue()
        assertEquals(10_000L, first?.timestampUs)
        assertTrue(firstPlayable)

        // Advance wall clock so targetPlaybackPts climbs just past the next frame's PTS:
        // targetPlaybackPts = 3_001 + 8_000 = 11_001 > front ts 11_000.
        wallClock = 3_001L
        assertEquals(11_001L, buffer.targetPlaybackPTS())
        val (second, secondPlayable) = buffer.dequeue()
        assertEquals(11_000L, second?.timestampUs)
        assertFalse(secondPlayable)
    }

    /**
     * Regression for the Android-only zero-tolerance audio-playhead gate. A frame whose PTS
     * sits behind the current live edge but still within `targetBufferingUs` of it must remain
     * playable. The removed audio-playhead path would have dropped it the moment the (drifting)
     * playhead crept past the frame's PTS, eventually collapsing video entirely.
     */
    @Test
    fun frameBehindLiveEdgeButWithinBufferingStaysPlayable() {
        var wallClock = 0L
        val buffer = JitterBuffer<Int>(
            targetBufferingUs = 50_000L,
            wallClockUs = { wallClock },
        )

        buffer.insert(item = 1, timestampUs = 100_000L)
        buffer.insert(item = 2, timestampUs = 150_000L)
        // maxOffset = 150_000; live edge = 150_000; targetPlaybackPts = 100_000.
        assertEquals(JitterBuffer.State.PLAYING, buffer.state)
        assertEquals(150_000L, buffer.estimatedLivePTS())
        assertEquals(100_000L, buffer.targetPlaybackPTS())

        // Front frame is a full 50ms behind the live edge yet exactly at the playback target.
        val (entry, playable) = buffer.dequeue()
        assertEquals(100_000L, entry?.timestampUs)
        assertTrue(playable)
    }

    /**
     * Long-run (~3 min at 30fps) steady live stream. Because playability tracks the buffer's
     * own live-edge estimate (not a drifting audio playhead), the freshest frame is always
     * playable and the buffer never collapses into an all-frames-dropped state. A consumer that
     * drains late frames and renders the first playable one keeps rendering for the whole run.
     */
    @Test
    fun longRunSteadyStreamNeverCollapsesToAllUnplayable() {
        var wallClock = 0L
        val frameIntervalUs = 33_333L
        val buffer = JitterBuffer<Int>(
            targetBufferingUs = 100_000L,
            wallClockUs = { wallClock },
        )

        var ts = 1_000_000L
        var id = 0
        var ticks = 0
        var renderedPlayable = 0
        var renderedInLastStretch = 0
        val totalTicks = 5_400 // ~3 minutes at 30fps
        val lastStretchStart = totalTicks - 1_000

        repeat(totalTicks) {
            buffer.insert(id++, ts)
            wallClock += frameIntervalUs
            ts += frameIntervalUs

            if (buffer.state != JitterBuffer.State.PLAYING) return@repeat

            // Drain: drop frames too far behind the live edge, render the first playable one.
            while (buffer.count > 0) {
                val (entry, playable) = buffer.dequeue()
                if (entry == null) break
                if (playable) {
                    renderedPlayable++
                    if (ticks >= lastStretchStart) renderedInLastStretch++
                    break
                }
            }
            ticks++
        }

        // The run must have actually played most frames and must still be playing at the end.
        assertTrue("expected sustained playback, got $renderedPlayable", renderedPlayable > 5_000)
        assertTrue(
            "video collapsed to all-unplayable in the final stretch",
            renderedInLastStretch > 900,
        )
    }
}

private fun testFrame(timestampUs: ULong): MoqFrame =
    MoqFrame(
        payload = ByteArray(1),
        timestampUs = timestampUs,
        keyframe = false,
    )
