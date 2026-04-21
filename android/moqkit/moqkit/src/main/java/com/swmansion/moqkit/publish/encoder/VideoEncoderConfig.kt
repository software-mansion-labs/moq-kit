package com.swmansion.moqkit.publish.encoder

enum class VideoCodec { H264, H265 }

data class VideoEncoderConfig(
    val codec: VideoCodec = VideoCodec.H264,
    val width: Int = 1920,
    val height: Int = 1080,
    val bitrate: Int = 1_500_000,
    val keyframeIntervalSeconds: Int = 2,
    val frameRate: Int = 30,
    val profile: String? = null,
) {
    val format: String
        get() = when (codec) {
            VideoCodec.H264 -> "avc1"
            VideoCodec.H265 -> "hev1"
        }
}
