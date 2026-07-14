package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderRecoveryExecutorTest {
    @Test
    fun firstFailureFlushesTheCurrentSession() {
        val sessions = mutableListOf<FakeDecoderSession>()
        val recoveries = mutableListOf<RecoveryAttempt>()
        val executor = createExecutor(sessions, recoveries)

        val original = executor.start()
        val result = executor.recover(IllegalStateException("codec failed"))

        assertTrue(result is DecoderRecoveryResult.Recovered)
        assertSame(original, executor.currentSession)
        assertEquals(1, original.flushCount)
        assertFalse(original.released)
        assertEquals(listOf(RecoveryAttempt(1, RecoveryStep.FLUSH, "codec failed")), recoveries)
    }

    @Test
    fun secondFailureRebuildsAndReleasesTheOldSession() {
        val sessions = mutableListOf<FakeDecoderSession>()
        val recoveries = mutableListOf<RecoveryAttempt>()
        val executor = createExecutor(sessions, recoveries)

        val original = executor.start()
        executor.recover(IllegalStateException("first"))
        val result = executor.recover(IllegalStateException("second"))

        assertTrue(result is DecoderRecoveryResult.Recovered)
        assertTrue(original.released)
        assertNotSame(original, executor.currentSession)
        assertEquals(2, sessions.size)
        assertEquals(RecoveryStep.REBUILD, recoveries.last().step)
    }

    @Test
    fun failedFlushFallsThroughToRebuild() {
        val sessions = mutableListOf<FakeDecoderSession>()
        val recoveries = mutableListOf<RecoveryAttempt>()
        val executor = createExecutor(sessions, recoveries)
        val original = executor.start()
        original.flushFailure = IllegalStateException("flush failed")

        val result = executor.recover(IllegalStateException("codec failed"))

        assertTrue(result is DecoderRecoveryResult.Recovered)
        assertTrue(original.released)
        assertEquals(listOf(RecoveryStep.FLUSH, RecoveryStep.REBUILD), recoveries.map { it.step })
    }

    @Test
    fun failedRebuildExhaustsRecoveryAndReleasesTheSession() {
        val sessions = mutableListOf<FakeDecoderSession>()
        val recoveries = mutableListOf<RecoveryAttempt>()
        var creationCount = 0
        val executor = DecoderRecoveryExecutor(
            supervisor = DecoderSupervisor(RecoveryPolicy(), FakeTimeSource(0)),
            createSession = {
                creationCount++
                if (creationCount == 2) error("rebuild failed")
                FakeDecoderSession().also(sessions::add)
            },
            onRecovery = recoveries::add,
        )
        val original = executor.start()
        executor.recover(IllegalStateException("first"))

        val result = executor.recover(IllegalStateException("second"))

        assertTrue(result is DecoderRecoveryResult.Failed)
        assertTrue(original.released)
        assertEquals(null, executor.currentSession)
        assertEquals(RecoveryStep.FAIL, recoveries.last().step)
    }

    private fun createExecutor(
        sessions: MutableList<FakeDecoderSession>,
        recoveries: MutableList<RecoveryAttempt>,
    ) = DecoderRecoveryExecutor(
        supervisor = DecoderSupervisor(RecoveryPolicy(), FakeTimeSource(0)),
        createSession = { FakeDecoderSession().also(sessions::add) },
        onRecovery = recoveries::add,
    )

    private class FakeDecoderSession : DecoderSession {
        var flushCount = 0
        var released = false
        var flushFailure: Throwable? = null

        override fun queueInput(frame: TimedFrame): Boolean = true

        override fun events(): Flow<DecoderEvent> = emptyFlow()

        override fun flush() {
            flushCount++
            flushFailure?.let { throw it }
        }

        override fun release() {
            released = true
        }
    }
}
