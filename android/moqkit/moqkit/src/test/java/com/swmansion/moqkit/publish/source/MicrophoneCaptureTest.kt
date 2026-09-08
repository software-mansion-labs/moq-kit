package com.swmansion.moqkit.publish.source

import com.swmansion.moqkit.publish.PublishedTrackState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class MicrophoneCaptureTest {
    @Test fun muteKeepsDeliveringPCMWithOriginalSizeAndTimestamp() {
        val microphone = MicrophoneCapture()
        var received = byteArrayOf()
        var timestamp = 0L
        var callbacks = 0
        microphone.onPcmData = { data, size, time ->
            received = data.copyOf(size)
            timestamp = time
            callbacks++
        }
        microphone.deliverPcm(byteArrayOf(1, 2, 3, 4), 4, 100)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), received)
        microphone.isMuted = true
        microphone.deliverPcm(byteArrayOf(1, 2, 3, 4), 2, 200)
        assertArrayEquals(byteArrayOf(0, 0), received)
        assertEquals(200L, timestamp)
        microphone.isMuted = false
        microphone.deliverPcm(byteArrayOf(5, 6), 2, 300)
        assertArrayEquals(byteArrayOf(5, 6), received)
        assertEquals(3, callbacks)
    }

    @Test fun captureStopIsReusableAndMutePersists() = runBlocking {
        val microphone = MicrophoneCapture()
        val states = mutableListOf<Boolean>()
        val cancel = microphone.captureLifecycle.observe { states += it.running }
        microphone.isMuted = true
        microphone.captureLifecycle.setRunning(true)
        microphone.stop()
        microphone.stop()
        microphone.captureLifecycle.setRunning(true)
        assertEquals(listOf(false, true, false, true), states)
        assertTrue(microphone.isMuted)
        cancel()
        microphone.close()
        assertTrue(microphone.captureLifecycle.snapshot.closed)
        assertNull(microphone.onPcmData)
    }

    @Test fun disableStopRestartAndTerminalDetachShareOneReconciler() {
        val lifecycle = CaptureLifecycle()
        var starts = 0
        var stops = 0
        var state: PublishedTrackState = PublishedTrackState.Idle
        val binding = CaptureTrackBinding(
            enabled = true,
            start = { starts++; val stop: () -> Unit = { stops++ }; stop },
            onState = { state = it }, onError = { throw AssertionError(it) }, onClosed = {},
        )
        binding.attach(lifecycle)
        assertEquals(0, starts)
        lifecycle.setRunning(true)
        lifecycle.setRunning(true)
        assertEquals(1, starts)
        binding.setEnabled(false)
        assertEquals(1, stops)
        assertEquals(PublishedTrackState.Disabled, state)
        lifecycle.setRunning(false)
        binding.setEnabled(true)
        assertEquals(PublishedTrackState.Idle, state)
        assertEquals(1, starts)
        lifecycle.setRunning(true)
        assertEquals(2, starts)
        binding.stop()
        lifecycle.setRunning(false)
        lifecycle.setRunning(true)
        assertEquals(2, starts)
        assertEquals(2, stops)
    }

    @Test fun runningSnapshotIsReplayedAndFailureCanBeRetried() {
        val lifecycle = CaptureLifecycle()
        lifecycle.setRunning(true)
        var attempts = 0
        var stopped = 0
        var closed = false
        val binding = CaptureTrackBinding(
            enabled = true,
            start = {
                attempts++
                if (attempts == 1) error("encoder unavailable")
                val stop: () -> Unit = { stopped++ }
                stop
            },
            onState = {}, onError = {}, onClosed = { closed = true },
        )
        assertThrows(IllegalStateException::class.java) { binding.attach(lifecycle) }
        binding.setEnabled(true)
        binding.setEnabled(true)
        assertEquals(2, attempts)
        lifecycle.close()
        assertTrue(closed)
        assertEquals(1, stopped)
        assertThrows(IllegalStateException::class.java) { binding.setEnabled(true) }
    }

    @Test fun reservationSurvivesStopAndRejectsSecondPublisher() {
        val lifecycle = CaptureLifecycle()
        val owner = Any()
        lifecycle.reserve(owner)
        lifecycle.setRunning(true)
        lifecycle.setRunning(false)
        assertThrows(IllegalStateException::class.java) { lifecycle.reserve(Any()) }
        lifecycle.release(owner)
        lifecycle.reserve(Any())
        lifecycle.close()
        assertThrows(IllegalStateException::class.java) { lifecycle.reserve(Any()) }
    }
}
