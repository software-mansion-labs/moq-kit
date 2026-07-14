package com.swmansion.moqkit.subscribe.internal.pipeline

internal data class DecodedFrame(
    val ptsUs: Long,
    val durationUs: Long? = null,
    val handle: Any? = null,
)

internal sealed interface RenderVerdict {
    data class RenderAt(val renderNanos: Long) : RenderVerdict
    data class DropLate(val latenessUs: Long) : RenderVerdict
    data class Hold(val recheckAfterUs: Long) : RenderVerdict
}

internal interface RenderSink {
    fun render(frame: DecodedFrame, atNanos: Long): Boolean
    fun drop(frame: DecodedFrame)
}

internal sealed interface RenderExecution {
    data class Rendered(val renderNanos: Long, val confirmed: Boolean) : RenderExecution
    data class DroppedLate(val latenessUs: Long) : RenderExecution
    data class Held(val recheckAfterUs: Long) : RenderExecution
}

/** Per-frame render timing policy, independent of MediaCodec output-buffer mechanics. */
internal class RenderScheduler(
    private val policy: RenderPolicy,
    private val clock: PlaybackClock,
) {
    fun verdict(decoded: DecodedFrame, nowNanos: Long): RenderVerdict {
        val mediaUs = clock.nowMediaUs() ?: return RenderVerdict.RenderAt(nowNanos)
        val deltaUs = decoded.ptsUs - mediaUs

        if (deltaUs < -policy.lateDropThresholdUs) {
            return RenderVerdict.DropLate(latenessUs = absoluteMagnitude(deltaUs))
        }
        if (deltaUs > policy.maxAheadUs) {
            return RenderVerdict.Hold(recheckAfterUs = deltaUs - policy.maxAheadUs)
        }

        val delayNanos = multiplyClamped(deltaUs.coerceAtLeast(0L), NANOS_PER_MICROSECOND)
        val latestNanos = addClamped(nowNanos, policy.maxScheduleAheadNanos)
        return RenderVerdict.RenderAt(
            renderNanos = addClamped(nowNanos, delayNanos).coerceIn(nowNanos, latestNanos),
        )
    }

    private fun absoluteMagnitude(value: Long): Long = when {
        value == Long.MIN_VALUE -> Long.MAX_VALUE
        value < 0L -> -value
        else -> value
    }

    private fun multiplyClamped(left: Long, right: Long): Long = try {
        Math.multiplyExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private fun addClamped(left: Long, right: Long): Long = try {
        Math.addExact(left, right)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }

    private companion object {
        const val NANOS_PER_MICROSECOND = 1_000L
    }
}

/** Executes pure scheduling verdicts while keeping platform output ownership in [RenderSink]. */
internal class RenderController(
    private val scheduler: RenderScheduler,
    private val sink: RenderSink,
) {
    fun process(frame: DecodedFrame, nowNanos: Long): RenderExecution =
        when (val verdict = scheduler.verdict(frame, nowNanos)) {
            is RenderVerdict.RenderAt -> RenderExecution.Rendered(
                renderNanos = verdict.renderNanos,
                confirmed = sink.render(frame, verdict.renderNanos),
            )
            is RenderVerdict.DropLate -> {
                sink.drop(frame)
                RenderExecution.DroppedLate(verdict.latenessUs)
            }
            is RenderVerdict.Hold -> RenderExecution.Held(verdict.recheckAfterUs)
        }
}
