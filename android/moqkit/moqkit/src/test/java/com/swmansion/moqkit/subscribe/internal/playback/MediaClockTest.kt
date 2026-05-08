package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}

private fun testFrame(timestampUs: ULong): MoqFrame =
    MoqFrame(
        payload = ByteArray(1),
        timestampUs = timestampUs,
        keyframe = false,
    )
