package com.swmansion.moqkit.subscribe.internal.pipeline

internal sealed interface SwitchState {
    data object Steady : SwitchState
    data class Preparing(val targetTrack: String) : SwitchState
    data class CuttingIn(val targetTrack: String, val keyframePtsUs: Long) : SwitchState
    data class FlushSwap(val targetTrack: String) : SwitchState
}

internal sealed interface SwitchDecision {
    data object Wait : SwitchDecision
    data class CutIn(val keyframePtsUs: Long) : SwitchDecision
    data object FlushSwap : SwitchDecision
    data class Abort(val targetTrack: String) : SwitchDecision
}

/** Pure rendition-switch state machine; the renderer only executes its decisions. */
internal class RenditionSwitchController(
    private val policy: SwitchPolicy,
) {
    var state: SwitchState = SwitchState.Steady
        private set

    fun begin(targetTrack: String) {
        require(targetTrack.isNotBlank()) { "target track must not be blank" }
        state = SwitchState.Preparing(targetTrack)
    }

    fun onKeyframeAvailable(lastFedPtsUs: Long, keyframePtsUs: Long): SwitchDecision {
        val preparing = state as? SwitchState.Preparing ?: return SwitchDecision.Wait
        val gapUs = positiveDifference(lastFedPtsUs, keyframePtsUs)
        return if (gapUs > policy.flushThresholdUs) {
            state = SwitchState.FlushSwap(preparing.targetTrack)
            SwitchDecision.FlushSwap
        } else {
            state = SwitchState.CuttingIn(preparing.targetTrack, keyframePtsUs)
            SwitchDecision.Wait
        }
    }

    fun onActiveProgress(lastFedPtsUs: Long): SwitchDecision = when (val current = state) {
        is SwitchState.CuttingIn -> if (lastFedPtsUs >= current.keyframePtsUs) {
            SwitchDecision.CutIn(current.keyframePtsUs)
        } else {
            SwitchDecision.Wait
        }
        is SwitchState.FlushSwap -> SwitchDecision.FlushSwap
        SwitchState.Steady,
        is SwitchState.Preparing -> SwitchDecision.Wait
    }

    fun onTimeout(): SwitchDecision {
        val preparing = state as? SwitchState.Preparing ?: return SwitchDecision.Wait
        state = SwitchState.Steady
        return SwitchDecision.Abort(preparing.targetTrack)
    }

    fun shouldDiscardPendingDelta(lastFedPtsUs: Long, framePtsUs: Long): Boolean =
        positiveDifference(lastFedPtsUs, framePtsUs) > policy.cutInWindowUs

    fun complete() {
        state = SwitchState.Steady
    }

    private fun positiveDifference(left: Long, right: Long): Long {
        if (left <= right) return 0L
        return try {
            Math.subtractExact(left, right)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
    }
}

/** Owns the active and pending resources associated with one rendition switch. */
internal class RenditionSwitchResources<Resource : Any>(
    initialActive: Resource? = null,
    private val close: (Resource) -> Unit,
) {
    private val lock = Any()

    @Volatile
    var active: Resource? = initialActive
        private set

    @Volatile
    var pending: Resource? = null
        private set

    fun replaceActive(resource: Resource) {
        val previous = synchronized(lock) {
            check(pending == null) { "cannot replace active resource during a pending switch" }
            active.also { active = resource }
        }
        previous?.let(close)
    }

    fun begin(resource: Resource) {
        synchronized(lock) {
            check(pending == null) { "rendition switch already has a pending resource" }
            pending = resource
        }
    }

    fun activate(expected: Resource): Boolean {
        val previous = synchronized(lock) {
            if (pending !== expected) return false
            active.also {
                active = expected
                pending = null
            }
        }
        previous?.let(close)
        return true
    }

    fun abort(expected: Resource): Boolean {
        val resource = synchronized(lock) {
            if (pending !== expected) return false
            pending.also { pending = null }
        }
        resource?.let(close)
        return true
    }

    fun close() {
        val resources = synchronized(lock) {
            listOfNotNull(pending, active).also {
                pending = null
                active = null
            }
        }
        resources.forEach(close)
    }
}
