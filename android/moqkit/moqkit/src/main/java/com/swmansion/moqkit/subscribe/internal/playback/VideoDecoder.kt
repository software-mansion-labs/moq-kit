package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.DecoderSession
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

private const val TAG = "VideoDecoder"

/** MediaCodec adapter. Decoder lifecycle and recovery policy live outside this class. */
internal class VideoDecoder(
    format: MediaFormat,
    surface: Surface,
    private val handler: Handler,
) : DecoderSession, VideoOutputSession {
    private val codec: MediaCodec
    private val decoderEvents = Channel<DecoderEvent>(Channel.UNLIMITED)
    private val availableInputBuffers = ArrayDeque<Int>()

    @Volatile
    private var released = false

    init {
        val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
        codec = MediaCodec.createDecoderByType(mime)
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (released) return
                availableInputBuffers.addLast(index)
                decoderEvents.trySend(DecoderEvent.InputAvailable)
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                if (released) return
                decoderEvents.trySend(
                    DecoderEvent.OutputReady(
                        timestampUs = info.presentationTimeUs,
                        handle = VideoOutputHandle(this@VideoDecoder, index),
                    ),
                )
            }

            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                if (released) return
                Log.e(TAG, "MediaCodec error", error)
                decoderEvents.trySend(DecoderEvent.Error(error))
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                if (released) return
                Log.d(TAG, "Output format changed: $format")
                decoderEvents.trySend(DecoderEvent.Reconfigured)
            }
        }, handler)

        codec.configure(format, surface, null, 0)
        Log.d(
            TAG,
            "VideoDecoder configured: $format, hardware accelerated = " +
                "${codec.codecInfo.isHardwareAccelerated}, decoder name = ${codec.codecInfo.name}",
        )
    }

    fun start() {
        check(!released) { "decoder is released" }
        codec.start()
        Log.d(TAG, "VideoDecoder started")
    }

    override fun events(): Flow<DecoderEvent> = decoderEvents.receiveAsFlow()

    override fun queueInput(frame: TimedFrame): Boolean {
        if (released) return false
        val index = availableInputBuffers.removeFirstOrNull() ?: return false
        return fillInputBuffer(index, frame.mediaFrame.payload, frame.timestampUs)
    }

    val canQueueInput: Boolean
        get() = !released && availableInputBuffers.isNotEmpty()

    /** Retarget decoded video output to a different surface without recreating the codec. */
    fun setOutputSurface(surface: Surface) {
        check(!released) { "decoder is released" }
        codec.setOutputSurface(surface)
        Log.d(TAG, "VideoDecoder output surface updated")
    }

    /** Queue codec-specific data before feeding an adaptively switched rendition. */
    fun queueCodecConfig(csd: ByteArray): Boolean {
        if (released) return false
        val index = availableInputBuffers.removeFirstOrNull() ?: return false
        return try {
            val inputBuffer = codec.getInputBuffer(index) ?: return false
            inputBuffer.clear()
            inputBuffer.put(csd)
            codec.queueInputBuffer(index, 0, csd.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
            true
        } catch (error: Throwable) {
            reportError("Error queuing codec config", error)
            false
        }
    }

    /** Release an output buffer for rendering at the specified timestamp. */
    fun releaseOutputBuffer(index: Int, renderTimestampNs: Long): Boolean =
        releaseOutputBuffer(index) { codec.releaseOutputBuffer(index, renderTimestampNs) }

    /** Release an output buffer without rendering. */
    fun releaseOutputBuffer(index: Int, render: Boolean): Boolean =
        releaseOutputBuffer(index) { codec.releaseOutputBuffer(index, render) }

    override fun renderOutput(index: Int, atNanos: Long): Boolean =
        releaseOutputBuffer(index, atNanos)

    override fun dropOutput(index: Int): Boolean = releaseOutputBuffer(index, false)

    override fun flush() {
        check(!released) { "decoder is released" }
        availableInputBuffers.clear()
        codec.flush()
        codec.start()
        Log.d(TAG, "VideoDecoder flushed")
    }

    override fun release() {
        if (released) return
        released = true
        availableInputBuffers.clear()
        decoderEvents.close()
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        try {
            codec.release()
        } catch (_: Throwable) {
        }
        Log.d(TAG, "VideoDecoder released")
    }

    private fun fillInputBuffer(index: Int, payload: ByteArray, timestampUs: Long): Boolean = try {
        val inputBuffer = codec.getInputBuffer(index) ?: return false
        inputBuffer.clear()
        inputBuffer.put(payload)
        codec.queueInputBuffer(index, 0, payload.size, timestampUs, 0)
        true
    } catch (error: Throwable) {
        reportError("Error filling input buffer", error)
        false
    }

    private inline fun releaseOutputBuffer(index: Int, release: () -> Unit): Boolean {
        if (released) return false
        return try {
            release()
            true
        } catch (error: Throwable) {
            reportError("Error releasing output buffer $index", error)
            false
        }
    }

    private fun reportError(message: String, error: Throwable) {
        if (released) return
        Log.e(TAG, message, error)
        decoderEvents.trySend(DecoderEvent.Error(error))
    }
}
