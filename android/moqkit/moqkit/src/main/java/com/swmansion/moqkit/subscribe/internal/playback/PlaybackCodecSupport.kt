package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodecList
import android.media.MediaFormat
import uniffi.moq.MoqAudio
import uniffi.moq.MoqVideo

internal data class PlaybackSupportResult(
    val isSupported: Boolean,
    val reason: String? = null,
)

internal object PlaybackCodecSupport {
    fun video(config: MoqVideo): PlaybackSupportResult {
        val format = VideoMediaFormatFactory.from(config) ?: probeVideoFormat(config)
            ?: return PlaybackSupportResult(false, "Unsupported video codec: ${config.codec}")
        return decoderSupport(format, "${config.codec} video decoder")
    }

    fun audio(config: MoqAudio): PlaybackSupportResult {
        val format = AudioMediaFormatFactory.from(config)
            ?: return PlaybackSupportResult(false, "Unsupported audio codec: ${config.codec}")
        return decoderSupport(format, "${config.codec} audio decoder")
    }

    private fun probeVideoFormat(config: MoqVideo): MediaFormat? {
        val codec = VideoCodec.from(config.codec)
        val mime = codec.mime ?: return null
        return MediaFormat.createVideoFormat(
            mime,
            config.coded?.width?.toInt() ?: 1920,
            config.coded?.height?.toInt() ?: 1080,
        )
    }

    private fun decoderSupport(format: MediaFormat, label: String): PlaybackSupportResult =
        try {
            val codecName = MediaCodecList(MediaCodecList.ALL_CODECS).findDecoderForFormat(format)
            if (codecName == null) {
                PlaybackSupportResult(false, "No $label is available for $format")
            } else {
                PlaybackSupportResult(true)
            }
        } catch (t: Throwable) {
            PlaybackSupportResult(false, "Failed to query $label support: ${t.message ?: t::class.java.simpleName}")
        }
}
