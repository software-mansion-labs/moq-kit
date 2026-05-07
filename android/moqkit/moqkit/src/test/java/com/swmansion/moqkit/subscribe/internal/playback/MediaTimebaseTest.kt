package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

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
}

class MediaTimebaseTest {
    @Test
    fun currentTimeCanBeSetAndReset() {
        val timebase = MediaTimebase()

        timebase.setCurrentTimeUs(19_000L)
        assertEquals(19_000L, timebase.currentTimeUs)

        timebase.reset()
        assertEquals(0L, timebase.currentTimeUs)
    }
}
