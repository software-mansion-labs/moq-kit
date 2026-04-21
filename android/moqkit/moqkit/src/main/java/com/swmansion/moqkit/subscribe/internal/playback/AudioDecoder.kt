package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

private const val TAG = "AudioDecoder"

/**
 * Wraps MediaCodec in async callback mode for decoding compressed audio to PCM16.
 *
 * Threading: Callbacks run on a dedicated HandlerThread.
 * Input management: pending input queue + available buffer indices, synchronized with Object lock.
 */
internal class AudioDecoder(
    format: MediaFormat,
    private val onDecoded: (pcmData: ShortArray, frameCount: Int, timestampUs: Long) -> Unit,
) {
    private val codec: MediaCodec
    private val handlerThread = HandlerThread("AudioDecoder").apply { start() }
    private val handler = Handler(handlerThread.looper)

    // Input management: synchronized on `inputLock`
    private val inputLock = Object()
    private val pendingInput = ArrayDeque<Pair<ByteArray, Long>>()
    private val availableInputBuffers = ArrayDeque<Int>()

    private val channels: Int = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

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
                try {
                    val outBuf = codec.getOutputBuffer(index) ?: return
                    outBuf.order(ByteOrder.nativeOrder())
                    val shortBuf = outBuf.asShortBuffer()
                    val sampleCount = info.size / 2 // 16-bit samples
                    val pcm = ShortArray(sampleCount)
                    shortBuf.get(pcm)
                    val frameCount = sampleCount / channels
                    onDecoded(pcm, frameCount, info.presentationTimeUs)
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing output buffer: $e")
                } finally {
                    codec.releaseOutputBuffer(index, false)
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "MediaCodec error: $e")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.d(TAG, "Output format changed: $format")
            }
        }, handler)

        codec.configure(format, null, null, 0)
        Log.d(TAG, "AudioDecoder configured: $format")
    }

    fun start() {
        codec.start()
        Log.d(TAG, "AudioDecoder started")
    }

    /** Submit a compressed audio frame for decoding. */
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

    /** Flush the codec and clear pending input. */
    fun flush() {
        synchronized(inputLock) {
            pendingInput.clear()
            availableInputBuffers.clear()
        }
        codec.flush()
        codec.start()
        Log.d(TAG, "AudioDecoder flushed")
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: Exception) {}
        try {
            codec.release()
        } catch (_: Exception) {}
        handlerThread.quitSafely()
        Log.d(TAG, "AudioDecoder released")
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
