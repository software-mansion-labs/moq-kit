package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimestampedQueueTest {
    @Test
    fun duplicatePresentationTimestampsRetainEveryValue() {
        val queue = TimestampedQueue<String>()

        queue.add(1_000L, "first")
        queue.add(1_000L, "second")

        assertEquals("first", queue.remove(1_000L))
        assertEquals("second", queue.remove(1_000L))
        assertNull(queue.remove(1_000L))
    }
}
