package com.swmansion.moqkit.publish.encoder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.publish.encoder.internal.AvccConverter

private const val TAG = "VideoEncoder"

internal data class EncodedVideoFrame(
    val data: ByteArray,
    val timestampUs: Long,
    val isKeyframe: Boolean,
    val initData: ByteArray?,
)

internal class VideoEncoder(val config: VideoEncoderConfig) {
    var encoderInputSurface: Surface? = null
        private set

    private var codec: MediaCodec? = null
    private var handler: ((EncodedVideoFrame) -> Unit)? = null
    private var sentInitData = false
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    fun start(onEncodedFrame: (EncodedVideoFrame) -> Unit) {
        handler = onEncodedFrame
        sentInitData = false
        sps = null
        pps = null

        val mimeType = when (config.codec) {
            VideoCodec.H264 -> MediaFormat.MIMETYPE_VIDEO_AVC
            VideoCodec.H265 -> MediaFormat.MIMETYPE_VIDEO_HEVC
        }

        val format = MediaFormat.createVideoFormat(mimeType, config.width, config.height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, config.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, config.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, config.keyframeIntervalSeconds)
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )
            config.profile?.let { setString("profile-level-id", it) }
        }

        val newCodec = MediaCodec.createEncoderByType(mimeType)
        newCodec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                // Not used for surface input mode
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo
            ) {
                try {
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        // CSD (codec-specific data): SPS/PPS for H.264, VPS+SPS+PPS for H.265
                        val buf = codec.getOutputBuffer(index) ?: return
                        val csd = ByteArray(info.size)
                        buf.position(info.offset)
                        buf.get(csd)
                        handleCsd(csd)
                        codec.releaseOutputBuffer(index, false)
                        return
                    }
                    if (info.size <= 0) {
                        codec.releaseOutputBuffer(index, false)
                        return
                    }
                    val buf = codec.getOutputBuffer(index) ?: run {
                        codec.releaseOutputBuffer(index, false)
                        return
                    }
                    val isKeyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    val raw = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.get(raw)
                    codec.releaseOutputBuffer(index, false)
                    handleEncodedData(raw, info.presentationTimeUs, isKeyframe)
                } catch (e: Exception) {
                    Log.e(TAG, "Output buffer error: $e")
                }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Codec error: $e")
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                extractCsdFromFormat(format)
            }
        })

        newCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoderInputSurface = newCodec.createInputSurface()
        newCodec.start()
        codec = newCodec
    }

    fun stop() {
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping codec: $e")
        }
        codec = null
        encoderInputSurface?.release()
        encoderInputSurface = null
        handler = null
    }

    private fun handleCsd(csd: ByteArray) {
        when (config.codec) {
            VideoCodec.H264 -> {
                val nalus = AvccConverter.extractNalusFromAnnexB(csd)
                for (nalu in nalus) {
                    val nalType = nalu[0].toInt() and 0x1F
                    if (nalType == 7) sps = nalu
                    else if (nalType == 8) pps = nalu
                }
            }
            VideoCodec.H265 -> {
                // Store entire CSD as Annex-B init data
                sps = csd
            }
        }
    }

    private fun extractCsdFromFormat(format: MediaFormat) {
        when (config.codec) {
            VideoCodec.H264 -> {
                val csd0 = format.getByteBuffer("csd-0")
                val csd1 = format.getByteBuffer("csd-1")
                if (csd0 != null) {
                    val bytes = ByteArray(csd0.remaining())
                    csd0.get(bytes)
                    val nalus = AvccConverter.extractNalusFromAnnexB(bytes)
                    for (nalu in nalus) {
                        val nalType = nalu[0].toInt() and 0x1F
                        if (nalType == 7) sps = nalu
                        else if (nalType == 8) pps = nalu
                    }
                }
                if (csd1 != null && pps == null) {
                    val bytes = ByteArray(csd1.remaining())
                    csd1.get(bytes)
                    val nalus = AvccConverter.extractNalusFromAnnexB(bytes)
                    for (nalu in nalus) {
                        val nalType = nalu[0].toInt() and 0x1F
                        if (nalType == 8) pps = nalu
                    }
                }
            }
            VideoCodec.H265 -> {
                val csd0 = format.getByteBuffer("csd-0")
                if (csd0 != null && sps == null) {
                    val bytes = ByteArray(csd0.remaining())
                    csd0.get(bytes)
                    sps = bytes
                }
            }
        }
    }

    private fun handleEncodedData(raw: ByteArray, presentationUs: Long, isKeyframe: Boolean) {
        val initData: ByteArray? = if (isKeyframe && !sentInitData) {
            buildInitData()?.also { sentInitData = true }
        } else null

        val payload = when (config.codec) {
            VideoCodec.H264 -> AvccConverter.annexBToAvcc(raw)
            VideoCodec.H265 -> raw  // pass Annex-B through
        }

        handler?.invoke(
            EncodedVideoFrame(
                data = payload,
                timestampUs = presentationUs,
                isKeyframe = isKeyframe,
                initData = initData,
            )
        )
    }

    private fun buildInitData(): ByteArray? {
        return when (config.codec) {
            VideoCodec.H264 -> {
                val s = sps ?: return null
                val p = pps ?: return null
                AvccConverter.buildAvcDecoderConfigurationRecord(s, p)
            }
            VideoCodec.H265 -> {
                sps  // already Annex-B VPS+SPS+PPS
            }
        }
    }
}
