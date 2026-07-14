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
        invalidateCurrentObservation()
        startObservation(session)
    }

    @Synchronized
    fun flush(session: Session) {
        invalidateCurrentObservation()
        session.flush()
        startObservation(session)
    }

    @Synchronized
    override fun close() {
        invalidateCurrentObservation()
    }

    private fun startObservation(session: Session) {
        val observedGeneration = ++generation
        job = scope.launch {
            session.events().collect { event ->
                if (generation == observedGeneration) onEvent(session, event)
            }
        }
    }

    private fun invalidateCurrentObservation() {
        generation++
        job?.cancel()
        job = null
    }
}
