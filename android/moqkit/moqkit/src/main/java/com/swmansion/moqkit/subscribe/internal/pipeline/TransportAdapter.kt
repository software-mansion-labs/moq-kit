package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.util.concurrent.atomic.AtomicBoolean

internal interface TransportAdapter {
    fun events(): Flow<IngestEvent>
    fun cancel()
}

/**
 * Compatibility adapter for the published FFI API, which currently exposes frames only.
 * Nullable group metadata is filled once `MoqMediaConsumer.next_event()` is available.
 */
internal class FlowTransportAdapter(
    private val frames: Flow<MediaFrame>,
    private val timeSource: TimeSource = MonotonicTimeSource,
    private val epoch: Long = 0L,
    private val onCancel: () -> Unit = {},
) : TransportAdapter {
    private val cancelled = AtomicBoolean(false)

    init {
        require(epoch >= 0L) { "epoch must be non-negative" }
    }

    val isCancelled: Boolean get() = cancelled.get()

    override fun events(): Flow<IngestEvent> = flow {
        try {
            frames.collect { frame ->
                if (cancelled.get()) return@collect
                emit(
                    IngestEvent.Frame(
                        frame = TimedFrame(mediaFrame = frame, epoch = epoch),
                        arrivalNanos = timeSource.nanoTime(),
                    ),
                )
            }
            emit(IngestEvent.Closed(error = null))
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            emit(
                IngestEvent.Closed(
                    error = PipelineError(
                        code = error::class.java.simpleName.ifEmpty { "UnknownError" },
                        message = error.message ?: error.toString(),
                    ),
                ),
            )
        }
    }

    override fun cancel() {
        if (cancelled.compareAndSet(false, true)) {
            onCancel()
        }
    }
}
