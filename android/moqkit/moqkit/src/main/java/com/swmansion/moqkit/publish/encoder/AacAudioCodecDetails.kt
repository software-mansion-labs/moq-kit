package com.swmansion.moqkit.publish.encoder

import android.media.MediaCodecInfo
import android.media.MediaFormat

internal object AacAudioCodecDetails : AudioCodecDetails {
    override val mimeType: String = MediaFormat.MIMETYPE_AUDIO_AAC

    override fun configureFormat(format: MediaFormat, config: AudioEncoderConfig) {
        format.setInteger(MediaFormat.KEY_BIT_RATE, config.bitrate)
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
    }

    override fun buildInitData(
        config: AudioEncoderConfig,
        outputFormat: MediaFormat?,
        codecConfig: ByteArray?,
    ): ByteArray {
        return outputFormat?.getByteArray("csd-0")
            ?: codecConfig
            ?: buildAudioSpecificConfig(config.sampleRate, config.channels)
    }

    private fun buildAudioSpecificConfig(sampleRate: Int, channels: Int): ByteArray {
        val objectType = 2 // AAC-LC
        val frequencyIndex = aacFrequencyIndex(sampleRate)
        val byte0 = ((objectType shl 3) or (frequencyIndex ushr 1)).toByte()
        val byte1 = (((frequencyIndex and 1) shl 7) or (channels shl 3)).toByte()
        return byteArrayOf(byte0, byte1)
    }

    private fun aacFrequencyIndex(sampleRate: Int): Int {
        val table = intArrayOf(
            96_000,
            88_200,
            64_000,
            48_000,
            44_100,
            32_000,
            24_000,
            22_050,
            16_000,
            12_000,
            11_025,
            8_000,
            7_350,
        )
        return table.indexOfFirst { it == sampleRate }.takeIf { it >= 0 } ?: 15
    }
}
