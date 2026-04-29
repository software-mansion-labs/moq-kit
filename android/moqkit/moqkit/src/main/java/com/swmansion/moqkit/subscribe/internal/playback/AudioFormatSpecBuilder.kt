package com.swmansion.moqkit.subscribe.internal.playback

import uniffi.moq.MoqAudio

internal object AudioFormatSpecBuilder {
    fun from(config: MoqAudio): AudioFormatSpec? {
        val mime = audioMime(config.codec) ?: return null
        val sampleRate = config.sampleRate.toInt()
        val channelCount = config.channelCount.toInt()
        val description = config.description

        val csdBuffers = when (mime) {
            CodecMime.AUDIO_AAC -> mapOf(
                "csd-0" to (description ?: AacCodecConfig.buildAudioSpecificConfig(sampleRate, channelCount)),
            )
            CodecMime.AUDIO_OPUS -> {
                val header = description ?: OpusCodecConfig.buildIdentificationHeader(sampleRate, channelCount)
                mapOf(
                    "csd-0" to header,
                    "csd-1" to OpusCodecConfig.codecDelayNs(header).toLittleEndianBytes(),
                    "csd-2" to OpusCodecConfig.SEEK_PRE_ROLL_NS.toLittleEndianBytes(),
                )
            }
            else -> return null
        }

        return AudioFormatSpec(
            mime = mime,
            sampleRate = sampleRate,
            channelCount = channelCount,
            csdBuffers = csdBuffers,
        )
    }

    private fun audioMime(codec: String): String? = when {
        codec.startsWith("mp4a") || codec.startsWith("aac") -> CodecMime.AUDIO_AAC
        codec.startsWith("opus") -> CodecMime.AUDIO_OPUS
        else -> null
    }
}
