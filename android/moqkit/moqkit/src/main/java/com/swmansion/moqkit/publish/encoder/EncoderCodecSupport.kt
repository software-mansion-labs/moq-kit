package com.swmansion.moqkit.publish.encoder

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

internal data class EncoderSupportResult(
    val isSupported: Boolean,
    val reason: String? = null,
)

internal object EncoderCodecSupport {
    fun video(config: VideoEncoderConfig): EncoderSupportResult {
        val format = MediaFormat.createVideoFormat(config.mimeType, config.width, config.height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, config.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, config.frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, config.keyframeIntervalSeconds)
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            config.profile?.let { setString("profile-level-id", it) }
        }
        return encoderSupport(format, "${config.codec} video encoder")
    }

    fun audio(config: AudioEncoderConfig): EncoderSupportResult {
        val details = audioCodecDetails(config.codec)
        val format = MediaFormat.createAudioFormat(details.mimeType, config.sampleRate, config.channels)
        details.configureFormat(format, config)
        return encoderSupport(format, "${config.codec} audio encoder")
    }

    private fun encoderSupport(format: MediaFormat, label: String): EncoderSupportResult =
        try {
            val codecName = MediaCodecList(MediaCodecList.ALL_CODECS).findEncoderForFormat(format)
            if (codecName == null) {
                EncoderSupportResult(false, "No $label is available for $format")
            } else {
                EncoderSupportResult(true)
            }
        } catch (t: Throwable) {
            EncoderSupportResult(false, "Failed to query $label support: ${t.message ?: t::class.java.simpleName}")
        }
}
