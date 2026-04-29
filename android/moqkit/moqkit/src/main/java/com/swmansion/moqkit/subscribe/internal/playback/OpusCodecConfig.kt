package com.swmansion.moqkit.subscribe.internal.playback

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object OpusCodecConfig {
    const val SEEK_PRE_ROLL_NS = 80_000_000L
    private const val DEFAULT_PRE_SKIP_SAMPLES = 312
    private const val OPUS_SAMPLE_RATE = 48_000

    fun buildIdentificationHeader(sampleRate: Int, channelCount: Int): ByteArray {
        return ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            .put("OpusHead".toByteArray(Charsets.US_ASCII))
            .put(1.toByte())
            .put(channelCount.toByte())
            .putShort(DEFAULT_PRE_SKIP_SAMPLES.toShort())
            .putInt(sampleRate)
            .putShort(0)
            .put(0.toByte())
            .array()
    }

    fun codecDelayNs(header: ByteArray): Long {
        val preSkipSamples = if (header.size >= 12) {
            ((header[11].toInt() and 0xFF) shl 8) or (header[10].toInt() and 0xFF)
        } else {
            DEFAULT_PRE_SKIP_SAMPLES
        }
        return preSkipSamples * 1_000_000_000L / OPUS_SAMPLE_RATE
    }
}
