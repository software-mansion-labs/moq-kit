package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.util.Log
import android.view.Surface

private const val TAG = "VideoDecoder"

/**
 * Wraps MediaCodec in async callback mode for decoding compressed video.
 * Configured with a Surface for hardware-accelerated rendering.
 * Does NOT auto-release output buffers -- caller controls release timing for scheduled display.
 *
 * Input is driven externally: when an input buffer becomes available, [onInputBufferAvailable]
 * is invoked so the caller can fill it via [fillInputBuffer].
 *
 * Threading: Callbacks run on a dedicated HandlerThread.
 */
internal class VideoDecoder(
    format: MediaFormat,
    surface: Surface,
    val handler: Handler,
    private val onInputBufferAvailable: (bufferIndex: Int) -> Unit,
    private val onOutputBufferAvailable: (bufferIndex: Int, timestampUs: Long) -> Unit,
) {
    private val codec: MediaCodec
    private var isConfigured: Boolean = false

    init {
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        codec = MediaCodec.createDecoderByType(mime)

        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                onInputBufferAvailable(index)
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

        try {
            codec.configure(format, surface, null, 0)
            isConfigured = true
            Log.d(TAG, "VideoDecoder configured: $format, hardware accelerated = ${codec.codecInfo.isHardwareAccelerated}")
        } catch (_: IllegalArgumentException) {
            Log.e(
                TAG,
                "MediaCodec.configure failed — " +
                        "mime=${format.getString(MediaFormat.KEY_MIME)}, " +
                        "size=${runCatching { format.getInteger(MediaFormat.KEY_WIDTH) }.getOrDefault(-1)}" +
                        "x${runCatching { format.getInteger(MediaFormat.KEY_HEIGHT) }.getOrDefault(-1)}, " +
                        "surface.isValid=${surface.isValid}, "
            )
        }
    }

    fun start() {
        if (isConfigured) {
            codec.start()
            Log.d(TAG, "VideoDecoder started")
        } else {
            Log.e(TAG, "VideoDecoder not started. MediaCodec is not configured")
        }
    }

    /** Retarget decoded video output to a different surface without recreating the codec. */
    fun setOutputSurface(surface: Surface) {
        codec.setOutputSurface(surface)
        Log.d(TAG, "VideoDecoder output surface updated")
    }

    /** Queue a codec-specific-data buffer to prepare for an adaptive resolution change. */
    fun queueCodecConfig(index: Int, csd: ByteArray) {
        try {
            val inputBuffer = codec.getInputBuffer(index) ?: return
            inputBuffer.clear()
            inputBuffer.put(csd)
            codec.queueInputBuffer(index, 0, csd.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
        } catch (e: Exception) {
            Log.e(TAG, "Error queuing codec config: $e")
        }
    }

    /** Fill an input buffer with a compressed video frame (Annex B format). */
    fun fillInputBuffer(index: Int, payload: ByteArray, timestampUs: Long) {
        try {
            val inputBuffer = codec.getInputBuffer(index) ?: return
            inputBuffer.clear()
            inputBuffer.put(payload)
            codec.queueInputBuffer(index, 0, payload.size, timestampUs, 0)
        } catch (e: Exception) {
            Log.e(TAG, "Error filling input buffer: $e")
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

    /**
     * Flush all pending input/output buffers and resume decoding from a clean state.
     * Required before feeding frames from a new rendition when a hard cut is needed.
     * After flush(), MediaCodec transitions to Flushed sub-state; start() resumes callbacks.
     */
    fun flush() {
        try {
            codec.flush()
            codec.start()
        } catch (e: Exception) {
            Log.e(TAG, "Error flushing codec: $e")
        }
        Log.d(TAG, "VideoDecoder flushed")
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: Exception) {}
        try {
            codec.release()
        } catch (_: Exception) {}
        Log.d(TAG, "VideoDecoder released")
    }
}
