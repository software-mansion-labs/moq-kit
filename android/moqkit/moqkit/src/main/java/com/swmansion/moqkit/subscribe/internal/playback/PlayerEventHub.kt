package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.PlayerEvent
import com.swmansion.moqkit.subscribe.PlayerEventType
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.time.Instant

internal class PlayerEventHub(
    private val clock: () -> Instant = Instant::now,
) {
    private val lock = Any()
    private val mutableEvents = MutableSharedFlow<PlayerEvent>(extraBufferCapacity = 64)
    private var sequence: Long = 0L

    val events: SharedFlow<PlayerEvent> = mutableEvents.asSharedFlow()

    fun emit(type: PlayerEventType): PlayerEvent {
        val event = synchronized(lock) {
            sequence += 1
            PlayerEvent(
                type = type,
                timestamp = clock(),
                sequence = sequence,
            )
        }
        mutableEvents.tryEmit(event)
        return event
    }
}
