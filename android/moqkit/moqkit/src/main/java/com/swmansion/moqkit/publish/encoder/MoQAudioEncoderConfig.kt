package com.swmansion.moqkit.publish.encoder

enum class MoQAudioCodec { AAC, OPUS }

data class MoQAudioEncoderConfig(
    val codec: MoQAudioCodec = MoQAudioCodec.AAC,
    val sampleRate: Int = 48_000,
    val channels: Int = 1,
    val bitrate: Int = 128_000,
) {
    val format: String
        get() = when (codec) {
            MoQAudioCodec.AAC -> "aac"
            MoQAudioCodec.OPUS -> "opus"
        }
}
