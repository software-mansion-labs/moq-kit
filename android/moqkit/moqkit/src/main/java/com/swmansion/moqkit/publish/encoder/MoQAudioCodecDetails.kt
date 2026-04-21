package com.swmansion.moqkit.publish.encoder

import android.media.MediaFormat

internal interface MoQAudioCodecDetails {
    val mimeType: String

    fun configureFormat(format: MediaFormat, config: MoQAudioEncoderConfig)

    fun buildInitData(
        config: MoQAudioEncoderConfig,
        outputFormat: MediaFormat?,
        codecConfig: ByteArray?,
    ): ByteArray
}

internal fun audioCodecDetails(codec: MoQAudioCodec): MoQAudioCodecDetails = when (codec) {
    MoQAudioCodec.AAC -> AacAudioCodecDetails
    MoQAudioCodec.OPUS -> OpusAudioCodecDetails
}

internal fun MediaFormat.getByteArray(key: String): ByteArray? {
    val value = getByteBuffer(key) ?: return null
    val bytes = ByteArray(value.remaining())
    value.duplicate().get(bytes)
    return bytes
}
