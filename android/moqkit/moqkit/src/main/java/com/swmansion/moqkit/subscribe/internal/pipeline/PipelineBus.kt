package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

internal class PipelineBus(capacity: Int = DEFAULT_CAPACITY) {
    private val mutableEvents: MutableSharedFlow<PipelineEvent>

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

    fun emit(event: PipelineEvent): Boolean = mutableEvents.tryEmit(event)

    private companion object {
        const val DEFAULT_CAPACITY = 256
    }
}
