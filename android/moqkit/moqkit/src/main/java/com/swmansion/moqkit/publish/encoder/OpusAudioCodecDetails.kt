package com.swmansion.moqkit.publish.encoder

import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object OpusAudioCodecDetails : AudioCodecDetails {
    override val mimeType: String = MediaFormat.MIMETYPE_AUDIO_OPUS

    override fun configureFormat(format: MediaFormat, config: AudioEncoderConfig) {
        format.setInteger(MediaFormat.KEY_BIT_RATE, config.bitrate)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
    }

    override fun buildInitData(
        config: AudioEncoderConfig,
        outputFormat: MediaFormat?,
        codecConfig: ByteArray?,
    ): ByteArray {
        return buildOpusHeader(config.sampleRate, config.channels)
    }

    private fun buildOpusHeader(sampleRate: Int, channels: Int): ByteArray {
        val preSkip: Short = 3_840
        return ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            .put("OpusHead".toByteArray(Charsets.US_ASCII))
            .put(1.toByte())
            .put(channels.toByte())
            .putShort(preSkip)
            .putInt(sampleRate)
            .putShort(0)
            .put(0.toByte())
            .array()
    }
}
