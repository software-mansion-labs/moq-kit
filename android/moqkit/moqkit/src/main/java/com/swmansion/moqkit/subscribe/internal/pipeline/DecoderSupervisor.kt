package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.flow.Flow

internal interface DecoderSession {
    fun configure(format: Any, surface: Any?)
    fun queueInput(frame: TimedFrame): Boolean
    fun events(): Flow<DecoderEvent>
    fun flush()
    fun release()
}

internal sealed interface DecoderEvent {
    data class OutputReady(val timestampUs: Long, val handle: Any) : DecoderEvent
    data class Error(val throwable: Throwable) : DecoderEvent
    object Reconfigured : DecoderEvent
}

internal sealed interface DecoderSupervisorState {
    object Configuring : DecoderSupervisorState
    object Running : DecoderSupervisorState
    data class Recovering(val attempt: Int, val step: RecoveryStep) : DecoderSupervisorState
    data class Failed(val trigger: String) : DecoderSupervisorState
}

internal sealed interface DecoderAction {
    object None : DecoderAction
    object RetryInput : DecoderAction
    object Flush : DecoderAction
    object Rebuild : DecoderAction
    object Fail : DecoderAction
}

/** Pure decoder lifecycle and bounded recovery-budget state machine. */
internal class DecoderSupervisor(
    private val policy: RecoveryPolicy,
    private val timeSource: TimeSource,
) {
    private val recoveryTimes = ArrayDeque<Long>()

    var state: DecoderSupervisorState = DecoderSupervisorState.Configuring
        private set

    val recoveriesInWindow: Int
        get() {
            pruneRecoveries(timeSource.nanoTime())
            return recoveryTimes.size
        }

    fun onConfigured() {
        check(state !is DecoderSupervisorState.Failed) { "failed decoder cannot be configured" }
        state = DecoderSupervisorState.Running
    }

    fun onInputQueued(accepted: Boolean): DecoderAction =
        if (accepted) DecoderAction.None else DecoderAction.RetryInput

    fun onError(trigger: String): DecoderAction {
        if (state is DecoderSupervisorState.Failed) return DecoderAction.Fail

        val now = timeSource.nanoTime()
        pruneRecoveries(now)
        if (recoveryTimes.size >= policy.maxRecoveries) {
            state = DecoderSupervisorState.Failed(trigger)
            return DecoderAction.Fail
        }

        val attempt = recoveryTimes.size + 1
        val step = policy.strategy.getOrElse(attempt - 1) { RecoveryStep.FAIL }
        if (step == RecoveryStep.FAIL) {
            state = DecoderSupervisorState.Failed(trigger)
            return DecoderAction.Fail
        }

        recoveryTimes.addLast(now)
        state = DecoderSupervisorState.Recovering(attempt, step)
        return when (step) {
            RecoveryStep.FLUSH -> DecoderAction.Flush
            RecoveryStep.REBUILD -> DecoderAction.Rebuild
            RecoveryStep.FAIL -> DecoderAction.Fail
        }
    }

    fun onRecoveryCompleted() {
        check(state is DecoderSupervisorState.Recovering) { "decoder is not recovering" }
        state = DecoderSupervisorState.Running
    }

    private fun pruneRecoveries(nowNanos: Long) {
        while (recoveryTimes.isNotEmpty()) {
            val oldest = recoveryTimes.first()
            val age = if (nowNanos >= oldest) nowNanos - oldest else 0L
            if (age <= policy.windowNanos) return
            recoveryTimes.removeFirst()
        }
    }
}
