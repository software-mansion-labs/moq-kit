package com.swmansion.moqkit.subscribe.internal.playback

/** Multimap that preserves submission order for duplicate presentation timestamps. */
internal class TimestampedQueue<T> {
    private val values = HashMap<Long, ArrayDeque<T>>()

    fun add(timestampUs: Long, value: T) {
        values.getOrPut(timestampUs) { ArrayDeque() }.addLast(value)
    }

    fun remove(timestampUs: Long): T? {
        val queue = values[timestampUs] ?: return null
        val value = queue.removeFirstOrNull()
        if (queue.isEmpty()) values.remove(timestampUs)
        return value
    }

    fun clear() {
        values.clear()
    }
}
