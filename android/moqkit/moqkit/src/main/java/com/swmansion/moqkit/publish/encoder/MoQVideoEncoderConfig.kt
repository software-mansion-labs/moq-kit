package com.swmansion.moqkit.publish.encoder

enum class MoQVideoCodec { H264, H265 }

data class MoQVideoEncoderConfig(
    val codec: MoQVideoCodec = MoQVideoCodec.H264,
    val width: Int = 1920,
    val height: Int = 1080,
    val bitrate: Int = 1_500_000,
    val keyframeIntervalSeconds: Int = 2,
    val frameRate: Int = 30,
    val profile: String? = null,
) {
    val format: String
        get() = when (codec) {
            MoQVideoCodec.H264 -> "avc1"
            MoQVideoCodec.H265 -> "hev1"
        }
}
