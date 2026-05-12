package com.swmansion.moqkit.publish.encoder

/**
 * Audio codecs supported by the Android publisher.
 */
enum class AudioCodec {
    /** AAC-LC audio. Broad device support and a good default choice. */
    AAC,

    /** Opus audio. Usually use a 48 kHz sample rate. */
    OPUS,
}

/**
 * Audio encoder settings for a publisher audio track.
 *
 * Start with the defaults unless the app has a specific quality or bandwidth target. Check
 * [isSupported] before enabling a setting in UI, because encoder availability can vary by
 * device.
 *
 * @property codec Audio codec to use.
 * @property sampleRate Samples per second. `48_000` is the recommended default.
 * @property channels Channel count. `1` is mono, `2` is stereo.
 * @property bitrate Target encoder bitrate in bits per second.
 */
data class AudioEncoderConfig(
    val codec: AudioCodec = AudioCodec.AAC,
    val sampleRate: Int = 48_000,
    val channels: Int = 1,
    val bitrate: Int = 128_000,
) {
    /** Catalog format string announced for this encoded audio track. */
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
