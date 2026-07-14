package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.swmansion.moqkit.subscribe.MediaFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderSession
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import java.nio.ByteOrder

private const val TAG = "AudioDecoder"

internal data class AudioPcmOutput(
    val samples: ShortArray,
    val frameCount: Int,
)

/** MediaCodec audio adapter. Buffer admission and recovery policy are owned by the pipeline. */
internal class AudioDecoder(
    format: MediaFormat,
    private val onDecoded: ((ShortArray, Int, Long) -> Unit)? = null,
    private val onError: ((Throwable) -> Unit)? = null,
) : DecoderSession {
    private val codec: MediaCodec
    private val handlerThread = HandlerThread("AudioDecoder").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val decoderEvents = Channel<DecoderEvent>(Channel.UNLIMITED)
    private val inputLock = Any()
    private val pendingInput = ArrayDeque<TimedFrame>()
    private val availableInputBuffers = ArrayDeque<Int>()
    private val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

    @Volatile
    private var released = false

    init {
        val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
        codec = MediaCodec.createDecoderByType(mime)
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (released) return
                synchronized(inputLock) {
                    if (released) return
                    val pending = pendingInput.removeFirstOrNull()
                    if (pending != null) {
                        fillInputBuffer(index, pending)
                    } else {
                        availableInputBuffers.addLast(index)
                        decoderEvents.trySend(DecoderEvent.InputAvailable)
                    }
                }
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                if (released) return
                try {
                    val output = codec.getOutputBuffer(index) ?: return
                    if (info.size <= 0) return
                    output.position(info.offset)
                    output.limit(info.offset + info.size)
                    output.order(ByteOrder.nativeOrder())
                    val shorts = output.asShortBuffer()
                    val samples = ShortArray(info.size / 2)
                    shorts.get(samples)
                    val frameCount = samples.size / channels
                    onDecoded?.invoke(samples, frameCount, info.presentationTimeUs)
                    decoderEvents.trySend(
                        DecoderEvent.OutputReady(
                            timestampUs = info.presentationTimeUs,
                            handle = AudioPcmOutput(samples, frameCount),
                        ),
                    )
                } catch (error: Throwable) {
                    reportError("Error processing output buffer", error)
                } finally {
                    releaseOutputBuffer(codec, index)
                }
            }

            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                reportError("MediaCodec error", error)
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                if (released) return
                Log.d(TAG, "Output format changed: $format")
                decoderEvents.trySend(DecoderEvent.Reconfigured)
            }
        }, handler)

        codec.configure(format, null, null, 0)
        Log.d(TAG, "AudioDecoder configured: $format")
    }

    fun start() {
        check(!released) { "decoder is released" }
        codec.start()
        Log.d(TAG, "AudioDecoder started")
    }

    override fun events(): Flow<DecoderEvent> = decoderEvents.receiveAsFlow()

    override fun queueInput(frame: TimedFrame): Boolean {
        if (released) return false
        handler.post {
            synchronized(inputLock) {
                if (released) return@synchronized
                val index = availableInputBuffers.removeFirstOrNull()
                if (index != null) fillInputBuffer(index, frame) else pendingInput.addLast(frame)
            }
        }
        return true
    }

    fun submitFrame(payload: ByteArray, timestampUs: Long) {
        queueInput(TimedFrame(MediaFrame(payload, timestampUs, keyframe = false)))
    }

    override fun flush() {
        check(!released) { "decoder is released" }
        synchronized(inputLock) {
            pendingInput.clear()
            availableInputBuffers.clear()
            codec.flush()
            codec.start()
        }
        Log.d(TAG, "AudioDecoder flushed")
    }

    override fun release() {
        synchronized(inputLock) {
            if (released) return
            released = true
            pendingInput.clear()
            availableInputBuffers.clear()
        }
        decoderEvents.close()
        handler.removeCallbacksAndMessages(null)
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        try {
            codec.release()
        } catch (_: Throwable) {
        }
        handlerThread.quitSafely()
        Log.d(TAG, "AudioDecoder released")
    }

    private fun fillInputBuffer(index: Int, frame: TimedFrame) {
        if (released) return
        try {
            val input = codec.getInputBuffer(index) ?: return
            input.clear()
            input.put(frame.mediaFrame.payload)
            codec.queueInputBuffer(index, 0, frame.sizeBytes, frame.timestampUs, 0)
        } catch (error: Throwable) {
            reportError("Error filling input buffer", error)
        }
    }

    private fun releaseOutputBuffer(codec: MediaCodec, index: Int) {
        if (released) return
        try {
            codec.releaseOutputBuffer(index, false)
        } catch (error: Throwable) {
            reportError("Error releasing output buffer", error)
        }
    }

    private fun reportError(message: String, error: Throwable) {
        if (released) return
        Log.e(TAG, message, error)
        onError?.invoke(error)
        decoderEvents.trySend(DecoderEvent.Error(error))
    }
}
