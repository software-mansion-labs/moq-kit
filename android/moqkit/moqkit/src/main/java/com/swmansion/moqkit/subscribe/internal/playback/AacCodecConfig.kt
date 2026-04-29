package com.swmansion.moqkit.subscribe.internal.playback

internal object AacCodecConfig {
    fun buildAudioSpecificConfig(sampleRate: Int, channelCount: Int): ByteArray {
        val sampleRateIndex = when (sampleRate) {
            96000 -> 0
            88200 -> 1
            64000 -> 2
            48000 -> 3
            44100 -> 4
            32000 -> 5
            24000 -> 6
            22050 -> 7
            16000 -> 8
            12000 -> 9
            11025 -> 10
            8000 -> 11
            else -> 4
        }

        return byteArrayOf(
            ((AAC_LC_OBJECT_TYPE shl 3) or (sampleRateIndex shr 1)).toByte(),
            (((sampleRateIndex and 0x01) shl 7) or (channelCount shl 3)).toByte(),
        )
    }

    private const val AAC_LC_OBJECT_TYPE = 2
}
