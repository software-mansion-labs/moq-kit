package com.swmansion.moqkit.publish.source

import com.swmansion.moqkit.publish.PublishedTrackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** One ordered control lane. Codec/frame callbacks enqueue notifications without waiting. */
internal object PublishControl {
    private val mutex = Mutex()
    private val notifications = CoroutineScope(SupervisorJob() + Dispatchers.Default.limitedParallelism(1))

    suspend fun <T> run(action: suspend () -> T): T =
        withContext(NonCancellable + Dispatchers.Default) { mutex.withLock { action() } }

    fun post(action: suspend () -> Unit) {
        notifications.launch { mutex.withLock { action() } }
    }
}

/** Replays current availability; changes and observers are confined to PublishControl. */
internal class CaptureLifecycle {
    data class Snapshot(val running: Boolean = false, val closed: Boolean = false, val generation: Long = 0)
    @Volatile var snapshot = Snapshot()
        private set
    private var owner: Any? = null
    private val observers = mutableMapOf<Any, (Snapshot) -> Unit>()

    @Synchronized fun reserve(id: Any) {
        check(!snapshot.closed) { "Capture is closed" }
        check(owner == null) { "Capture already has a publication attachment" }
        owner = id
    }

    @Synchronized fun release(id: Any) {
        if (owner === id) owner = null
    }

    fun setRunning(value: Boolean) {
        if (snapshot.closed || snapshot.running == value) return
        snapshot = snapshot.copy(running = value, generation = snapshot.generation + if (value) 1 else 0)
        observers.values.toList().forEach { it(snapshot) }
    }

    fun close() {
        if (snapshot.closed) return
        synchronized(this) {
            snapshot = snapshot.copy(running = false, closed = true)
            owner = null
        }
        observers.values.toList().forEach { it(snapshot) }
        observers.clear()
    }

    fun observe(observer: (Snapshot) -> Unit): () -> Unit {
        val id = Any()
        observers[id] = observer
        observer(snapshot)
        return { observers.remove(id); Unit }
    }
}

/** The sole owner of activation/deactivation for a logical media publication. */
internal class CaptureTrackBinding(
    private var enabled: Boolean,
    private val start: () -> (() -> Unit),
    private val onState: (PublishedTrackState) -> Unit,
    private val onError: (Exception) -> Unit,
    private val onClosed: () -> Unit,
) {
    private var closed = false
    private var source = CaptureLifecycle.Snapshot(running = true)
    private var generation: Long? = null
    private var stopEncoding: (() -> Unit)? = null
    private var cancelObservation: (() -> Unit)? = null
    var failure: Exception? = null
        private set

    fun attach(lifecycle: CaptureLifecycle?) {
        if (lifecycle == null) reconcile()
        else {
            val cancel = lifecycle.observe { snapshot ->
                if (!closed) {
                    if (snapshot.generation != source.generation) failure = null
                    source = snapshot
                    reconcile()
                }
            }
            if (closed) cancel() else cancelObservation = cancel
        }
        failure?.let { throw it }
    }

    fun setEnabled(value: Boolean) {
        check(!closed) { "Track is stopped" }
        enabled = value
        failure = null
        reconcile()
        failure?.let { throw it }
    }

    fun fail(error: Exception) {
        if (closed) return
        stopOutput()
        failure = error
        onState(PublishedTrackState.Failed(error.message ?: "Media publication failed"))
        onError(error)
    }

    private fun reconcile() {
        if (closed) return
        if (source.closed) { stop(); onClosed(); return }
        if (!enabled || !source.running) {
            stopOutput()
            onState(if (enabled) PublishedTrackState.Idle else PublishedTrackState.Disabled)
            return
        }
        if (generation != source.generation) stopOutput()
        if (stopEncoding != null || failure != null) return
        try {
            onState(PublishedTrackState.Starting)
            stopEncoding = start()
            generation = source.generation
        } catch (e: Exception) { fail(e) }
    }

    private fun stopOutput() {
        val stop = stopEncoding
        stopEncoding = null
        generation = null
        try { stop?.invoke() } catch (e: Exception) { onError(e) }
    }

    fun stop() {
        if (closed) return
        closed = true
        stopOutput()
        cancelObservation?.invoke()
        cancelObservation = null
    }
}
