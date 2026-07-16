package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** Keeps decoder event collection attached when a flush replaces the session's event stream. */
internal class DecoderEventObserver<Session : DecoderSession>(
    private val scope: CoroutineScope,
    private val onEvent: (Session, DecoderEvent) -> Unit,
) : AutoCloseable {
    private var job: Job? = null

    @Volatile
    private var generation = 0L

    @Synchronized
    fun observe(session: Session) {
        invalidate()
        start(session)
    }

    @Synchronized
    fun flush(session: Session) {
        invalidate()
        session.flush()
        start(session)
    }

    @Synchronized
    override fun close() {
        invalidate()
    }

    private fun start(session: Session) {
        val observedGeneration = ++generation
        job = scope.launch {
            session.events().collect { event ->
                if (generation == observedGeneration) onEvent(session, event)
            }
        }
    }

    private fun invalidate() {
        generation++
        job?.cancel()
        job = null
    }
}
