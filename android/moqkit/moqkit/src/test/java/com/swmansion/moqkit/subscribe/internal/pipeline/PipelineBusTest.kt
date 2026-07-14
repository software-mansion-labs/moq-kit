package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.PipelineEvent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PipelineBusTest {
    @Test
    fun publishesTypedEventsWithoutReplay() = runBlocking {
        val bus = PipelineBus(capacity = 4)
        val subscribed = CompletableDeferred<Unit>()
        val received = async {
            subscribed.complete(Unit)
            bus.events.first()
        }
        subscribed.await()
        withTimeout(1_000L) {
            while (bus.subscriptionCount == 0) kotlinx.coroutines.yield()
        }
        val event = PipelineEvent.FrameDropped(
            context = context(),
            stage = DropStage.BUFFER,
            reason = DropReason.BACKLOG_OVERFLOW,
            count = 2,
            bytes = 512,
        )

        assertTrue(bus.emit(event))
        assertEquals(event, withTimeout(1_000L) { received.await() })

        assertFalse(bus.events.replayCache.contains(event))
    }

    @Test
    fun requiresPositiveCapacity() {
        assertThrows(IllegalArgumentException::class.java) {
            PipelineBus(capacity = 0)
        }
    }

    @Test
    fun synchronousObserverCanBeDetached() {
        val bus = PipelineBus(capacity = 4)
        val observed = mutableListOf<PipelineEvent>()
        val registration = bus.observe { observed += it }
        val first = PipelineEvent.FrameDropped(
            context = context(),
            stage = DropStage.BUFFER,
            reason = DropReason.BACKLOG_OVERFLOW,
        )
        val second = first.copy(ptsUs = 2)

        bus.emit(first)
        registration.close()
        bus.emit(second)

        assertEquals(listOf(first), observed)
    }

    private fun context() = PipelineContext(
        trackId = "video/main",
        mediaKind = PipelineMediaKind.VIDEO,
        timestampNanos = 42L,
    )
}
