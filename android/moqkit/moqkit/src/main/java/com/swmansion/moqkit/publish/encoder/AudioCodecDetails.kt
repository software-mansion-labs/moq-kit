package com.swmansion.moqkit.publish.encoder

import android.media.MediaFormat

internal interface AudioCodecDetails {
    val mimeType: String

    fun configureFormat(format: MediaFormat, config: AudioEncoderConfig)

    fun buildInitData(
        config: AudioEncoderConfig,
        outputFormat: MediaFormat?,
        codecConfig: ByteArray?,
    ): ByteArray
}

internal fun audioCodecDetails(codec: AudioCodec): AudioCodecDetails = when (codec) {
    AudioCodec.AAC -> AacAudioCodecDetails
    AudioCodec.OPUS -> OpusAudioCodecDetails
}

internal fun MediaFormat.getByteArray(key: String): ByteArray? {
    val value = getByteBuffer(key) ?: return null
    val bytes = ByteArray(value.remaining())
    value.duplicate().get(bytes)
    return bytes
}
