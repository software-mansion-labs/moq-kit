package com.swmansion.moqkit.subscribe.internal.playback

import uniffi.moq.MoqVideo

internal object VideoFormatSpecBuilder {
    fun fromDescription(config: MoqVideo): VideoFormatSpec? {
        val description = config.description ?: return null
        val codec = VideoCodec.from(config.codec)
        val mime = codec.mime ?: return null
        val dimensions = config.dimensions()
        val csdBuffers = when (codec) {
            VideoCodec.Avc -> H264CodecConfig.csdFromAvcc(description)
            VideoCodec.Hevc -> HevcCodecConfig.csdFromHvcc(description)
            VideoCodec.Av1 -> mapOf("csd-0" to description)
            VideoCodec.Unsupported -> return null
        }

        return VideoFormatSpec(
            mime = mime,
            width = dimensions.width,
            height = dimensions.height,
            csdBuffers = csdBuffers,
        )
    }

    fun fromInBandKeyframe(config: MoqVideo, payload: ByteArray): VideoFormatSpec? {
        val codec = VideoCodec.from(config.codec)
        val mime = codec.mime ?: return null
        val dimensions = config.dimensions()
        val csdBuffers = when (codec) {
            VideoCodec.Avc -> H264CodecConfig.csdFromAnnexBKeyframe(payload) ?: return null
            VideoCodec.Hevc -> HevcCodecConfig.csdFromAnnexBKeyframe(payload) ?: return null
            VideoCodec.Av1 -> Av1CodecConfig.csdFromTemporalUnit(payload) ?: return null
            VideoCodec.Unsupported -> return null
        }

        return VideoFormatSpec(
            mime = mime,
            width = dimensions.width,
            height = dimensions.height,
            csdBuffers = csdBuffers,
        )
    }

    private fun MoqVideo.dimensions(): VideoDimensions {
        return VideoDimensions(
            width = coded?.width?.toInt() ?: 1920,
            height = coded?.height?.toInt() ?: 1080,
        )
    }

    private data class VideoDimensions(val width: Int, val height: Int)
}
