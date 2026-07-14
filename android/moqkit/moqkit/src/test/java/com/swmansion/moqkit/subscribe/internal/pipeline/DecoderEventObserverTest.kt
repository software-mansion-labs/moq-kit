package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Test

class DecoderEventObserverTest {
    @Test
    fun resumesObservationWhenFlushRotatesTheEventStream() = runBlocking {
        val session = RotatingDecoderSession()
        val received = mutableListOf<DecoderEvent>()
        val observer = DecoderEventObserver<RotatingDecoderSession>(this) { _, event ->
            received += event
        }

        observer.observe(session)
        session.send(DecoderEvent.InputAvailable)
        awaitEventCount(received, 1)

        session.send(DecoderEvent.Error(IllegalStateException("stale before flush")))
        observer.flush(session)
        session.send(DecoderEvent.Reconfigured)
        awaitEventCount(received, 2)

        assertEquals(
            listOf(DecoderEvent.InputAvailable, DecoderEvent.Reconfigured),
            received,
        )
        observer.close()
    }

    private suspend fun awaitEventCount(events: List<DecoderEvent>, expected: Int) {
        withTimeout(1_000L) {
            while (events.size < expected) yield()
        }
    }

    private class RotatingDecoderSession : DecoderSession {
        private var channel = Channel<DecoderEvent>(Channel.UNLIMITED)

        override fun queueInput(frame: TimedFrame): Boolean = true

        override fun events(): Flow<DecoderEvent> = channel.receiveAsFlow()

        override fun flush() {
            val previous = channel
            channel = Channel(Channel.UNLIMITED)
            previous.close()
        }

        override fun release() {
            channel.close()
        }

        fun send(event: DecoderEvent) {
            check(channel.trySend(event).isSuccess)
        }
    }
}
