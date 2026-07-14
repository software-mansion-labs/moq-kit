package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.PipelineEvent
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.CopyOnWriteArrayList

internal class PipelineBus(capacity: Int = DEFAULT_CAPACITY) {
    private val mutableEvents: MutableSharedFlow<PipelineEvent>
    private val observers = CopyOnWriteArrayList<(PipelineEvent) -> Unit>()

    init {
        require(capacity > 0) { "capacity must be positive" }
        mutableEvents = MutableSharedFlow(
            replay = 0,
            extraBufferCapacity = capacity,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
    }

    val events: SharedFlow<PipelineEvent> = mutableEvents.asSharedFlow()

    val subscriptionCount: Int
        get() = mutableEvents.subscriptionCount.value

    fun emit(event: PipelineEvent): Boolean {
        observers.forEach { observer -> runCatching { observer(event) } }
        return mutableEvents.tryEmit(event)
    }

    fun observe(observer: (PipelineEvent) -> Unit): AutoCloseable {
        observers += observer
        return AutoCloseable { observers -= observer }
    }

    private companion object {
        const val DEFAULT_CAPACITY = 256
    }
}
