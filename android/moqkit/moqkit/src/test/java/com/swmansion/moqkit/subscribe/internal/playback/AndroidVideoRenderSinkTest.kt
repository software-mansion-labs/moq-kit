package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.pipeline.DecodedFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidVideoRenderSinkTest {
    @Test
    fun renderReleasesCodecOutputAtScheduledTime() {
        val session = FakeVideoOutputSession()
        val sink = AndroidVideoRenderSink()

        assertTrue(
            sink.render(
                DecodedFrame(ptsUs = 10, handle = VideoOutputHandle(session, 7)),
                atNanos = 20,
            ),
        )
        assertEquals(listOf(7 to 20L), session.rendered)
    }

    @Test
    fun dropReleasesCodecOutputWithoutRendering() {
        val session = FakeVideoOutputSession()
        val sink = AndroidVideoRenderSink()

        sink.drop(DecodedFrame(ptsUs = 10, handle = VideoOutputHandle(session, 7)))

        assertEquals(listOf(7), session.dropped)
    }

    @Test
    fun renderFailsWhenOwningSessionRejectsStaleOutput() {
        val session = FakeVideoOutputSession(renderResult = false)
        val sink = AndroidVideoRenderSink()

        assertFalse(
            sink.render(
                DecodedFrame(ptsUs = 10, handle = VideoOutputHandle(session, 7)),
                atNanos = 20,
            ),
        )
    }

    private class FakeVideoOutputSession(
        private val renderResult: Boolean = true,
    ) : VideoOutputSession {
        val rendered = mutableListOf<Pair<Int, Long>>()
        val dropped = mutableListOf<Int>()

        override fun renderOutput(index: Int, atNanos: Long): Boolean {
            rendered += index to atNanos
            return renderResult
        }

        override fun dropOutput(index: Int): Boolean {
            dropped += index
            return true
        }
    }
}
