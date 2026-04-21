package com.swmansion.moqkit.publish.encoder

enum class AudioCodec { AAC, OPUS }

data class AudioEncoderConfig(
    val codec: AudioCodec = AudioCodec.AAC,
    val sampleRate: Int = 48_000,
    val channels: Int = 1,
    val bitrate: Int = 128_000,
) {
    val format: String
        get() = when (codec) {
            AudioCodec.AAC -> "aac"
            AudioCodec.OPUS -> "opus"
        }
}
