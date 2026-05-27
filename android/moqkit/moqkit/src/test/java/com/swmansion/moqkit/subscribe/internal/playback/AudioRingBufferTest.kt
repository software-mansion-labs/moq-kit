package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.time.Duration

class AudioRingBufferTest {
    @Test
    fun constructorUsesDurationForCapacity() {
        val buffer = AudioRingBuffer(
            rate = 48_000,
            channels = 2,
            latency = Duration.ofMillis(100),
        )

        assertEquals(4_800, buffer.capacity)
    }

    @Test
    fun constructorDoesNotTruncateSubMillisecondDuration() {
        val buffer = AudioRingBuffer(
            rate = 48_000,
            channels = 1,
            latency = Duration.ofNanos(1),
        )

        assertEquals(1, buffer.capacity)
    }

    @Test
    fun resizeUsesDurationForCapacity() {
        val buffer = AudioRingBuffer(
            rate = 1_000,
            channels = 1,
            latency = Duration.ofMillis(10),
        )

        buffer.resize(Duration.ofMillis(20))

        assertEquals(20, buffer.capacity)
    }

    @Test
    fun zeroLatencyIsInvalid() {
        try {
            AudioRingBuffer(
                rate = 48_000,
                channels = 1,
                latency = Duration.ZERO,
            )
            fail("Expected zero latency to be rejected")
        } catch (error: IllegalArgumentException) {
            assertEquals("invalid latency", error.message)
        }
    }
}
