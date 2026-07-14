package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderSupervisorTest {
    @Test
    fun recoveryStrategyAdvancesFromFlushToRebuildThenFailsAtBudget() {
        val time = FakeTimeSource(0)
        val supervisor = DecoderSupervisor(
            RecoveryPolicy(maxRecoveries = 2, windowNanos = 1_000),
            time,
        )
        supervisor.onConfigured()

        assertEquals(DecoderAction.Flush, supervisor.onError("codec"))
        supervisor.onRecoveryCompleted()
        time.advance(100)
        assertEquals(DecoderAction.Rebuild, supervisor.onError("codec"))
        supervisor.onRecoveryCompleted()
        time.advance(100)
        assertEquals(DecoderAction.Fail, supervisor.onError("codec"))
        assertTrue(supervisor.state is DecoderSupervisorState.Failed)
    }

    @Test
    fun recoveryBudgetResetsAfterItsWindow() {
        val time = FakeTimeSource(0)
        val supervisor = DecoderSupervisor(
            RecoveryPolicy(maxRecoveries = 1, windowNanos = 100),
            time,
        )
        supervisor.onConfigured()
        assertEquals(DecoderAction.Flush, supervisor.onError("first"))
        supervisor.onRecoveryCompleted()

        time.advance(101)

        assertEquals(DecoderAction.Flush, supervisor.onError("later"))
    }

    @Test
    fun inputBackpressureDoesNotConsumeRecoveryBudget() {
        val supervisor = DecoderSupervisor(RecoveryPolicy(), FakeTimeSource(0))
        supervisor.onConfigured()

        assertEquals(DecoderAction.RetryInput, supervisor.onInputQueued(accepted = false))
        assertEquals(DecoderAction.None, supervisor.onInputQueued(accepted = true))
        assertEquals(0, supervisor.recoveriesInWindow)
    }
}
