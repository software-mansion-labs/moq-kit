package com.swmansion.moqkit.subscribe.internal.playback

internal enum class VideoCodec(val mime: String?) {
    Avc(CodecMime.VIDEO_AVC),
    Hevc(CodecMime.VIDEO_HEVC),
    Av1(CodecMime.VIDEO_AV1),
    Unsupported(null);

    val usesLengthPrefixedSamples: Boolean
        get() = this == Avc || this == Hevc

    companion object {
        fun from(codec: String): VideoCodec = when {
            codec.startsWith("avc") -> Avc
            codec.startsWith("hev") || codec.startsWith("hvc") -> Hevc
            codec.startsWith("av0") -> Av1
            else -> Unsupported
        }
    }
}
