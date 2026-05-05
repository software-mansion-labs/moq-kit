package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaCodecList
import uniffi.moq.MoqAudio
import uniffi.moq.MoqVideo

internal data class PlaybackSupportResult(
    val isSupported: Boolean,
    val reason: String? = null,
)

internal object PlaybackCodecSupport {
    fun video(config: MoqVideo): PlaybackSupportResult {
        val mime = videoMime(config.codec)
            ?: return PlaybackSupportResult(false, "Unsupported video codec: ${config.codec}")
        return decoderSupport(mime, "${config.codec} video decoder")
    }

    fun audio(config: MoqAudio): PlaybackSupportResult {
        val mime = audioMime(config.codec)
            ?: return PlaybackSupportResult(false, "Unsupported audio codec: ${config.codec}")
        return decoderSupport(mime, "${config.codec} audio decoder")
    }

    internal fun videoMime(codec: String): String? = VideoCodec.from(codec.lowercase()).mime

    internal fun audioMime(codec: String): String? {
        val normalized = codec.lowercase()
        return when {
            normalized.startsWith("mp4a") || normalized.startsWith("aac") -> CodecMime.AUDIO_AAC
            normalized.startsWith("opus") -> CodecMime.AUDIO_OPUS
            else -> null
        }
    }

    private fun decoderSupport(mime: String, label: String): PlaybackSupportResult =
        try {
            val hasDecoder = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { codecInfo ->
                !codecInfo.isEncoder && codecInfo.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }
            if (hasDecoder) {
                PlaybackSupportResult(true)
            } else {
                PlaybackSupportResult(false, "No $label is available for $mime")
            }
        } catch (t: Throwable) {
            PlaybackSupportResult(false, "Failed to query $label support: ${t.message ?: t::class.java.simpleName}")
        }
}
