package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.PipelineEvent

internal enum class PipelineLogLevel { DEBUG, WARN }

internal data class PipelineLogEntry(
    val level: PipelineLogLevel,
    val message: String,
)

/** Formats actionable pipeline diagnostics for Logcat without logging high-volume happy paths. */
internal object PipelineDiagnosticLogFormatter {
    fun format(event: PipelineEvent): PipelineLogEntry? = when (event) {
        is PipelineEvent.FrameDropped -> PipelineLogEntry(
            level = PipelineLogLevel.DEBUG,
            message = buildString {
                append("${event.mediaLabel} frames dropped track='${event.context.trackId}'")
                append(" stage=${event.stage} reason=${event.reason} count=${event.count}")
                event.ptsUs?.let { append(" ptsUs=$it") }
                event.groupSequence?.let { append(" groupSequence=$it") }
                if (event.bytes > 0L) append(" bytes=${event.bytes}")
            },
        )

        is PipelineEvent.DecoderFlushed -> PipelineLogEntry(
            level = PipelineLogLevel.WARN,
            message = "${event.mediaLabel} decoder flushed track='${event.context.trackId}' " +
                "reason=${event.reason} trigger='${event.trigger}' " +
                "droppedFrames=${event.droppedFrames}",
        )

        is PipelineEvent.DecoderRecovery -> PipelineLogEntry(
            level = PipelineLogLevel.WARN,
            message = "${event.mediaLabel} decoder recovery track='${event.context.trackId}' " +
                "attempt=${event.attempt} step=${event.step} trigger='${event.trigger}'",
        )

        is PipelineEvent.Discontinuity -> PipelineLogEntry(
            level = PipelineLogLevel.WARN,
            message = "${event.mediaLabel} discontinuity track='${event.context.trackId}' " +
                "epoch=${event.epoch} reason=${event.reason}",
        )

        is PipelineEvent.StallStarted -> PipelineLogEntry(
            level = PipelineLogLevel.WARN,
            message = "${event.mediaLabel} stall started track='${event.context.trackId}' " +
                "cause=${event.cause}",
        )

        is PipelineEvent.StallEnded -> PipelineLogEntry(
            level = PipelineLogLevel.DEBUG,
            message = "${event.mediaLabel} stall ended track='${event.context.trackId}' " +
                "cause=${event.cause} durationMs=${event.durationMillis}",
        )

        else -> null
    }

    private val PipelineEvent.mediaLabel: String
        get() = context.mediaKind.name.lowercase().replaceFirstChar(Char::uppercase)
}
