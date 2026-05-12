package com.swmansion.moqkit.publish.encoder

import android.media.MediaFormat

/**
 * Video codecs supported by the Android publisher.
 */
enum class VideoCodec {
    /** H.264 / AVC. Broad device support and a good default choice. */
    H264,

    /** H.265 / HEVC. Use only after checking device support. */
    H265,
}

/**
 * Video encoder settings for a publisher video track.
 *
 * Start with the defaults unless the app has a specific quality, resolution, or bandwidth
 * target. Check [isSupported] before enabling a setting in UI, because encoder availability
 * can vary by device.
 *
 * @property codec Video codec to use.
 * @property width Encoded frame width in pixels.
 * @property height Encoded frame height in pixels.
 * @property bitrate Target encoder bitrate in bits per second.
 * @property keyframeIntervalSeconds Requested interval between keyframes.
 * @property frameRate Target frames per second.
 * @property profile Optional Android MediaCodec profile name. Leave `null` for the platform
 *   default.
 */
data class VideoEncoderConfig(
    val codec: VideoCodec = VideoCodec.H264,
    val width: Int = 1920,
    val height: Int = 1080,
    val bitrate: Int = 1_500_000,
    val keyframeIntervalSeconds: Int = 2,
    val frameRate: Int = 30,
    val profile: String? = null,
) {
    /** Catalog format string announced for this encoded video track. */
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
