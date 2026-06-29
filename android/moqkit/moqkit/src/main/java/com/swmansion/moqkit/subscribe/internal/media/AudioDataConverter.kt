package com.swmansion.moqkit.subscribe.internal.media

import com.swmansion.moqkit.subscribe.AudioData
import com.swmansion.moqkit.subscribe.AudioDataFormat
import com.swmansion.moqkit.subscribe.AudioSampleFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor
import kotlin.math.roundToInt

internal class AudioDataConverter(
    private val sourceSampleRate: UInt,
    private val sourceChannelCount: UInt,
    requestedFormat: AudioDataFormat,
) {
    private val targetSampleRate = requestedFormat.sampleRate ?: sourceSampleRate
    private val targetChannelCount = requestedFormat.channelCount ?: sourceChannelCount
    private val sampleFormat = requestedFormat.sampleFormat

    init {
        require(sourceSampleRate > 0u) { "Audio track sample rate must be greater than zero" }
        require(sourceChannelCount > 0u) { "Audio track channel count must be greater than zero" }
        require(targetSampleRate > 0u) { "Audio data sample rate must be greater than zero" }
        require(targetChannelCount > 0u) { "Audio data channel count must be greater than zero" }
    }

    fun convert(
        pcmData: ShortArray,
        frameCount: Int,
        timestampUs: Long,
    ): AudioData {
        val sourceChannels = sourceChannelCount.toInt()
        val expectedSamples = frameCount * sourceChannels
        require(frameCount >= 0) { "Audio data frame count must be non-negative" }
        require(pcmData.size >= expectedSamples) {
            "Audio data contains fewer samples than declared frame count"
        }

        val samples = remapAndResample(pcmData, frameCount)
        val bytes = when (sampleFormat) {
            AudioSampleFormat.Float32 -> float32InterleavedBytes(samples)
            AudioSampleFormat.Int16 -> int16InterleavedBytes(samples)
        }

        return AudioData(
            bytes = bytes,
            timestampUs = timestampUs,
            sampleRate = targetSampleRate,
            channelCount = targetChannelCount,
            sampleFormat = sampleFormat,
            frameCount = samples.size / targetChannelCount.toInt(),
        )
    }

    // Android playback APIs resample internally, but this stream emits app-owned PCM buffers.
    private fun remapAndResample(pcmData: ShortArray, frameCount: Int): FloatArray {
        if (frameCount == 0) return FloatArray(0)

        val sourceRate = sourceSampleRate.toDouble()
        val targetRate = targetSampleRate.toDouble()
        val outputFrames = if (sourceSampleRate == targetSampleRate) {
            frameCount
        } else {
            maxOf(1, (frameCount * targetRate / sourceRate).roundToInt())
        }
        val targetChannels = targetChannelCount.toInt()
        val output = FloatArray(outputFrames * targetChannels)

        for (outFrame in 0 until outputFrames) {
            val sourcePosition = if (sourceSampleRate == targetSampleRate) {
                outFrame.toDouble()
            } else {
                outFrame * sourceRate / targetRate
            }
            val baseFrame = floor(sourcePosition).toInt().coerceIn(0, frameCount - 1)
            val nextFrame = (baseFrame + 1).coerceAtMost(frameCount - 1)
            val fraction = (sourcePosition - baseFrame).coerceIn(0.0, 1.0).toFloat()

            for (channel in 0 until targetChannels) {
                val baseSample = remapSample(pcmData, baseFrame, channel)
                val nextSample = remapSample(pcmData, nextFrame, channel)
                output[outFrame * targetChannels + channel] =
                    baseSample + (nextSample - baseSample) * fraction
            }
        }

        return output
    }

    private fun remapSample(
        pcmData: ShortArray,
        frame: Int,
        targetChannel: Int,
    ): Float {
        val sourceChannels = sourceChannelCount.toInt()
        if (targetChannelCount == 1u && sourceChannels > 1) {
            var sum = 0f
            for (channel in 0 until sourceChannels) {
                sum += sampleToFloat(pcmData[frame * sourceChannels + channel])
            }
            return sum / sourceChannels
        }

        val sourceChannel = if (sourceChannels == 1) {
            0
        } else {
            targetChannel.coerceAtMost(sourceChannels - 1)
        }
        return sampleToFloat(pcmData[frame * sourceChannels + sourceChannel])
    }

    private fun float32InterleavedBytes(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer
            .allocate(samples.size * Float.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { buffer.putFloat(it) }
        return buffer.array()
    }

    private fun int16InterleavedBytes(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer
            .allocate(samples.size * Short.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { sample ->
            val clamped = sample.coerceIn(-1f, 1f)
            val scale = if (clamped < 0f) 32_768f else 32_767f
            buffer.putShort(
                (clamped * scale)
                    .roundToInt()
                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    .toShort(),
            )
        }
        return buffer.array()
    }

    private fun sampleToFloat(sample: Short): Float =
        if (sample < 0) {
            sample.toFloat() / 32_768f
        } else {
            sample.toFloat() / 32_767f
        }
}
