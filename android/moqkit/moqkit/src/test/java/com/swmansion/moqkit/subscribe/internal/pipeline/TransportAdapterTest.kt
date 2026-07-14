package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransportAdapterTest {
    @Test
    fun legacyAdapterPreservesFramesAndAddsArrivalHeartbeat() = runBlocking {
        val time = FakeTimeSource(10L)
        val first = MediaFrame(byteArrayOf(1), timestampUs = 100L, keyframe = true)
        val second = MediaFrame(byteArrayOf(2), timestampUs = 133L, keyframe = false)
        val adapter = FlowTransportAdapter(
            frames = flowOf(first, second),
            timeSource = time,
        )

        val events = adapter.events().toList()

        assertEquals(3, events.size)
        val firstEvent = events[0] as IngestEvent.Frame
        assertEquals(first, firstEvent.frame.mediaFrame)
        assertEquals(10L, firstEvent.arrivalNanos)
        assertNull(firstEvent.frame.groupSequence)
        assertNull(firstEvent.frame.frameIndex)
        assertEquals(0L, firstEvent.frame.epoch)
        assertTrue(events[2] is IngestEvent.Closed)
        assertNull((events[2] as IngestEvent.Closed).error)
    }

    @Test
    fun legacyAdapterConvertsFailureToStructuredClose() = runBlocking {
        val adapter = FlowTransportAdapter(
            frames = kotlinx.coroutines.flow.flow {
                throw IllegalStateException("relay closed")
            },
            timeSource = FakeTimeSource(0L),
        )

        val events = adapter.events().toList()

        val closed = events.single() as IngestEvent.Closed
        assertEquals("IllegalStateException", closed.error?.code)
        assertEquals("relay closed", closed.error?.message)
    }

    @Test
    fun cancelIsIdempotent() {
        var cancelled = 0
        val adapter = FlowTransportAdapter(
            frames = flowOf(),
            timeSource = FakeTimeSource(0L),
            onCancel = { cancelled += 1 },
        )

        assertFalse(adapter.isCancelled)
        adapter.cancel()
        adapter.cancel()

        assertTrue(adapter.isCancelled)
        assertEquals(1, cancelled)
    }
}

internal class FakeTimeSource(
    private var now: Long,
) : TimeSource {
    override fun nanoTime(): Long = now

    fun advance(nanos: Long) {
        now += nanos
    }
}
