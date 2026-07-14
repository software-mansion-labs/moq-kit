package com.swmansion.moqkit.subscribe.internal.pipeline

import kotlinx.coroutines.flow.Flow

internal interface DecoderSession {
    fun queueInput(frame: TimedFrame): Boolean
    fun events(): Flow<DecoderEvent>
    fun flush()
    fun release()
}

internal sealed interface DecoderEvent {
    object InputAvailable : DecoderEvent
    data class OutputReady(val timestampUs: Long, val handle: Any) : DecoderEvent
    data class Error(val throwable: Throwable) : DecoderEvent
    object Reconfigured : DecoderEvent
}

internal data class RecoveryAttempt(
    val attempt: Int,
    val step: RecoveryStep,
    val trigger: String,
)

internal sealed interface DecoderRecoveryResult<out Session : DecoderSession> {
    data class Recovered<Session : DecoderSession>(
        val session: Session,
        val attempt: RecoveryAttempt,
    ) : DecoderRecoveryResult<Session>

    data class Failed(val error: Throwable) : DecoderRecoveryResult<Nothing>
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

/**
 * Owns one generation-scoped decoder session and executes the recovery action selected by
 * [DecoderSupervisor]. Released sessions cannot route events into their replacements.
 */
internal class DecoderRecoveryExecutor<Session : DecoderSession>(
    private val supervisor: DecoderSupervisor,
    private val createSession: () -> Session,
    private val onRecovery: (RecoveryAttempt) -> Unit = {},
) {
    var currentSession: Session? = null
        private set

    fun start(): Session {
        check(currentSession == null) { "decoder session is already started" }
        return createSession().also {
            currentSession = it
            supervisor.onConfigured()
        }
    }

    fun recover(error: Throwable): DecoderRecoveryResult<Session> {
        var failure = error
        while (true) {
            val action = supervisor.onError(failure.message ?: failure.javaClass.simpleName)
            val state = supervisor.state
            val attempt = when (state) {
                is DecoderSupervisorState.Recovering -> RecoveryAttempt(
                    attempt = state.attempt,
                    step = state.step,
                    trigger = failure.message ?: failure.javaClass.simpleName,
                )
                is DecoderSupervisorState.Failed -> RecoveryAttempt(
                    attempt = supervisor.recoveriesInWindow + 1,
                    step = RecoveryStep.FAIL,
                    trigger = state.trigger,
                )
                DecoderSupervisorState.Configuring,
                DecoderSupervisorState.Running -> error("decoder recovery action without recovery state")
            }
            onRecovery(attempt)

            when (action) {
                DecoderAction.Flush -> {
                    val session = currentSession
                        ?: return DecoderRecoveryResult.Failed(failure)
                    try {
                        session.flush()
                        supervisor.onRecoveryCompleted()
                        return DecoderRecoveryResult.Recovered(session, attempt)
                    } catch (flushError: Throwable) {
                        failure = flushError
                    }
                }

                DecoderAction.Rebuild -> {
                    currentSession?.release()
                    currentSession = null
                    try {
                        val session = createSession()
                        currentSession = session
                        supervisor.onRecoveryCompleted()
                        return DecoderRecoveryResult.Recovered(session, attempt)
                    } catch (rebuildError: Throwable) {
                        failure = rebuildError
                    }
                }

                DecoderAction.Fail -> {
                    currentSession?.release()
                    currentSession = null
                    return DecoderRecoveryResult.Failed(failure)
                }

                DecoderAction.None,
                DecoderAction.RetryInput -> error("invalid decoder recovery action: $action")
            }
        }
    }

    fun release() {
        currentSession?.release()
        currentSession = null
    }
}
