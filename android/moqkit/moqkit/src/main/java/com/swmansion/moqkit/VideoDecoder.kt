package com.swmansion.moqkit

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface

private const val TAG = "VideoDecoder"

/**
 * Wraps MediaCodec in async callback mode for decoding compressed video.
 * Configured with a Surface for hardware-accelerated rendering.
 * Does NOT auto-release output buffers — caller controls release timing for scheduled display.
 *
 * Threading: Callbacks run on a dedicated HandlerThread.
 */
internal class VideoDecoder(
    format: MediaFormat,
    surface: Surface,
    private val onOutputBufferAvailable: (bufferIndex: Int, timestampUs: Long) -> Unit,
) {
    private val codec: MediaCodec
    val handlerThread = HandlerThread("MoQ-VideoDecoder").apply { start() }
    val handler = Handler(handlerThread.looper)

    // Input management: synchronized on `inputLock`
    private val inputLock = Object()
    private val pendingInput = ArrayDeque<Pair<ByteArray, Long>>()
    private val availableInputBuffers = ArrayDeque<Int>()

    init {
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        codec = MediaCodec.createDecoderByType(mime)

        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                synchronized(inputLock) {
                    val pending = pendingInput.removeFirstOrNull()
                    if (pending != null) {
                        fillInputBuffer(index, pending.first, pending.second)
                    } else {
                        availableInputBuffers.addLast(index)
                    }
                }
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                onOutputBufferAvailable(index, info.presentationTimeUs)
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "MediaCodec error: $e")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.d(TAG, "Output format changed: $format")
            }
        }, handler)

        codec.configure(format, surface, null, 0)
        Log.d(TAG, "VideoDecoder configured: $format")
    }

    fun start() {
        codec.start()
        Log.d(TAG, "VideoDecoder started")
    }

    /** Submit a compressed video frame (Annex B format) for decoding. */
    fun submitFrame(payload: ByteArray, timestampUs: Long) {
        synchronized(inputLock) {
            val bufferIndex = availableInputBuffers.removeFirstOrNull()
            if (bufferIndex != null) {
                fillInputBuffer(bufferIndex, payload, timestampUs)
            } else {
                pendingInput.addLast(payload to timestampUs)
            }
        }
    }

    /** Release an output buffer for rendering at the specified timestamp. */
    fun releaseOutputBuffer(index: Int, renderTimestampNs: Long) {
        try {
            codec.releaseOutputBuffer(index, renderTimestampNs)
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing output buffer for render: $e")
        }
    }

    /** Release an output buffer without rendering (drop). */
    fun releaseOutputBuffer(index: Int, render: Boolean) {
        try {
            codec.releaseOutputBuffer(index, render)
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing output buffer: $e")
        }
    }

    /** Flush the codec and clear pending input. */
    fun flush() {
        synchronized(inputLock) {
            pendingInput.clear()
            availableInputBuffers.clear()
        }
        codec.flush()
        codec.start()
        Log.d(TAG, "VideoDecoder flushed")
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: Exception) {}
        try {
            codec.release()
        } catch (_: Exception) {}
        handlerThread.quitSafely()
        Log.d(TAG, "VideoDecoder released")
    }

    private fun fillInputBuffer(index: Int, payload: ByteArray, timestampUs: Long) {
        try {
            val inputBuffer = codec.getInputBuffer(index) ?: return
            inputBuffer.clear()
            inputBuffer.put(payload)
            codec.queueInputBuffer(index, 0, payload.size, timestampUs, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Error filling input buffer: $e")
        }
    }
}
