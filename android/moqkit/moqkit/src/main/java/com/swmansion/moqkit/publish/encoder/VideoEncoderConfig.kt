package com.swmansion.moqkit.publish.encoder

import android.media.MediaFormat

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

    /** Whether this exact encoder configuration can be created on the current device. */
    val isSupported: Boolean
        get() = EncoderCodecSupport.video(this).isSupported

    /** Human-readable reason this configuration is unsupported, or null when supported. */
    val unsupportedReason: String?
        get() = EncoderCodecSupport.video(this).reason

    internal val mimeType: String
        get() = when (codec) {
            VideoCodec.H264 -> MediaFormat.MIMETYPE_VIDEO_AVC
            VideoCodec.H265 -> MediaFormat.MIMETYPE_VIDEO_HEVC
        }

    companion object {
        /** Video codecs that can be encoded on the current device with default settings. */
        fun supportedCodecs(): List<VideoCodec> =
            VideoCodec.entries.filter { codec -> VideoEncoderConfig(codec = codec).isSupported }
    }
}
