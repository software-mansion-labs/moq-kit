package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.prefixLengthToAnnexB
import uniffi.moq.MoqVideo

internal fun interface VideoPayloadTransform {
    fun apply(payload: ByteArray): ByteArray
}

internal object VideoPayloadTransformBuilder {
    fun from(config: MoqVideo): VideoPayloadTransform {
        val codec = VideoCodec.from(config.codec)
        val convertToAnnexB = config.description != null && codec.usesLengthPrefixedSamples

        return when (codec) {
            VideoCodec.Avc -> VideoPayloadTransform { payload ->
                val annexBPayload = if (convertToAnnexB) payload.prefixLengthToAnnexB() else payload
                H264SpsRewriter.rewriteAnnexBStream(annexBPayload)
            }
            VideoCodec.Hevc -> VideoPayloadTransform { payload ->
                if (convertToAnnexB) payload.prefixLengthToAnnexB() else payload
            }
            VideoCodec.Av1,
            VideoCodec.Unsupported -> VideoPayloadTransform { payload -> payload }
        }
    }
}
