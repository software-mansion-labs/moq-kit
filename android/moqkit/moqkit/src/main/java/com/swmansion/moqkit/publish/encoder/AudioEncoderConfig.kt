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

    /** Whether this exact encoder configuration can be created on the current device. */
    val isSupported: Boolean
        get() = EncoderCodecSupport.audio(this).isSupported

    /** Human-readable reason this configuration is unsupported, or null when supported. */
    val unsupportedReason: String?
        get() = EncoderCodecSupport.audio(this).reason

    companion object {
        /** Audio codecs that can be encoded on the current device with default settings. */
        fun supportedCodecs(): List<AudioCodec> =
            AudioCodec.entries.filter { codec -> AudioEncoderConfig(codec = codec).isSupported }
    }
}
