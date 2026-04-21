package com.swmansion.moqkit.publish.encoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import com.swmansion.moqkit.publish.source.AudioFrameSource
import java.util.concurrent.LinkedBlockingDeque

private const val TAG = "AudioEncoder"

internal data class EncodedAudioFrame(
    val data: ByteArray,
    val timestampUs: Long,
    val initData: ByteArray?,
)

private data class PcmChunk(val data: ByteArray, val size: Int, val timestampUs: Long)

internal class AudioEncoder(val config: AudioEncoderConfig) {
    private val pcmQueue = LinkedBlockingDeque<PcmChunk>(64)
    private val inputBufferQueue = LinkedBlockingDeque<Int>(32)
    private val codecDetails = audioCodecDetails(config.codec)
    private var codec: MediaCodec? = null
    private var handler: ((EncodedAudioFrame) -> Unit)? = null
    private var sentInitData = false
    private var outputFormat: MediaFormat? = null
    private var codecConfigData: ByteArray? = null

    fun start(source: AudioFrameSource, onEncodedFrame: (EncodedAudioFrame) -> Unit) {
        handler = onEncodedFrame
        sentInitData = false
        outputFormat = null
        codecConfigData = null

        val mimeType = codecDetails.mimeType
        val format = MediaFormat.createAudioFormat(mimeType, config.sampleRate, config.channels)
        codecDetails.configureFormat(format, config)

        val newCodec = MediaCodec.createEncoderByType(mimeType)
        newCodec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                inputBufferQueue.offer(index)
                tryFeed(codec)
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo
            ) {
                try {
                    val buf = codec.getOutputBuffer(index) ?: run {
                        codec.releaseOutputBuffer(index, false)
                        return
                    }
                    val bytes = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.get(bytes)
                    codec.releaseOutputBuffer(index, false)

                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        codecConfigData = bytes
                        return
                    }

                    val initData: ByteArray? = if (!sentInitData) {
                        sentInitData = true
                        codecDetails.buildInitData(config, outputFormat, codecConfigData)
                    } else null

                    handler?.invoke(
                        EncodedAudioFrame(
                            data = bytes,
                            timestampUs = info.presentationTimeUs,
                            initData = initData,
                        )
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "Output buffer error: $e")
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Codec error: $e")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                outputFormat = format
            }
        })

        newCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        newCodec.start()
        codec = newCodec

        source.onPcmData = { data, size, timestampUs ->
            pcmQueue.offer(PcmChunk(data.copyOf(size), size, timestampUs))
            codec?.let { tryFeed(it) }
        }
    }

    fun stop() {
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping codec: $e")
        }
        codec = null
        handler = null
        pcmQueue.clear()
        inputBufferQueue.clear()
        outputFormat = null
        codecConfigData = null
    }

    @Synchronized
    private fun tryFeed(codec: MediaCodec) {
        while (true) {
            val chunk = pcmQueue.peek() ?: return
            val index = inputBufferQueue.poll() ?: return
            pcmQueue.poll()
            try {
                val buf = codec.getInputBuffer(index) ?: continue
                buf.clear()
                buf.put(chunk.data, 0, chunk.size)
                codec.queueInputBuffer(index, 0, chunk.size, chunk.timestampUs, 0)
            } catch (e: Exception) {
                Log.e(TAG, "queueInputBuffer error: $e")
            }
        }
    }
}
