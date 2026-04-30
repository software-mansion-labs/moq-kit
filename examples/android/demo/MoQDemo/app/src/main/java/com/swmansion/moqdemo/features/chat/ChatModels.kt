package com.swmansion.moqdemo.features.chat

import java.util.UUID

data class ChatPayload(
    val from: String,
    val message: String,
)

data class ChatMessage(
    val direction: Direction,
    val from: String,
    val text: String,
    val broadcastPath: String,
    val timestampMs: Long = System.currentTimeMillis(),
    val id: String = UUID.randomUUID().toString(),
) {
    enum class Direction {
        Local,
        Remote,
    }

    val isLocal: Boolean
        get() = direction == Direction.Local
}

