package com.swmansion.moqkit.subscribe

import com.swmansion.moqkit.subscribe.internal.media.AudioDataConverter
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import uniffi.moq.Container
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Duration

class AudioDataStreamTest {
    @Test
    fun audioTrackRequestBuildsDecoderConfig() {
        val codecDescription = byteArrayOf(0x11, 0x22)
        val initializationData = byteArrayOf(0x01, 0x02, 0x03)
        val request = AudioTrackRequest(
            name = "known-audio",
            container = MediaContainer.Cmaf(initializationData),
            codec = "opus",
            codecDescription = codecDescription,
            sampleRate = 48_000u,
            channelCount = 2u,
            bitrate = 96_000uL,
            targetBuffering = Duration.ofMillis(250),
        )

        val raw = request.rawConfig
        assertEquals("known-audio", request.media.name)
        assertEquals(MediaContainer.Cmaf(initializationData), request.media.container)
        assertEquals(Duration.ofMillis(250), request.media.targetBuffering)
        assertEquals("opus", raw.codec)
        assertArrayEquals(codecDescription, raw.description)
        assertEquals(48_000u, raw.sampleRate)
        assertEquals(2u, raw.channelCount)
        assertEquals(96_000uL, raw.bitrate)
        assertTrue(raw.container is Container.Cmaf)
        assertArrayEquals(initializationData, (raw.container as Container.Cmaf).init)
    }

    @Test
    fun byteArrayBackedTypesUseContentEquality() {
        val initData = byteArrayOf(1, 2)
        val cmaf = MediaContainer.Cmaf(initData)
        initData[0] = 9

        assertArrayEquals(byteArrayOf(1, 2), cmaf.initializationData)
        assertEquals(
            MediaContainer.Cmaf(byteArrayOf(1, 2)),
            cmaf,
        )
        assertEquals(
            AudioData(
                bytes = byteArrayOf(1, 2),
                timestampUs = 10,
                sampleRate = 48_000u,
                channelCount = 1u,
                sampleFormat = AudioSampleFormat.Int16,
                frameCount = 1,
            ),
            AudioData(
                bytes = byteArrayOf(1, 2),
                timestampUs = 10,
                sampleRate = 48_000u,
                channelCount = 1u,
                sampleFormat = AudioSampleFormat.Int16,
                frameCount = 1,
            ),
        )
    }

    @Test
    fun float32OutputIsInterleavedWithMetadata() {
        val converter = AudioDataConverter(
            sourceSampleRate = 48_000u,
            sourceChannelCount = 2u,
            requestedFormat = AudioDataFormat(),
        )

        val output = converter.convert(
            pcmData = shortArrayOf(0, Short.MAX_VALUE, 16_384, -16_384, Short.MIN_VALUE, 8_192),
            frameCount = 3,
            timestampUs = 123_456,
        )

        assertEquals(123_456, output.timestampUs)
        assertEquals(48_000u, output.sampleRate)
        assertEquals(2u, output.channelCount)
        assertEquals(AudioSampleFormat.Float32, output.sampleFormat)
        assertEquals(3, output.frameCount)
        assertEquals(3 * 2 * Float.SIZE_BYTES, output.bytes.size)

        assertFloatSamples(
            float32Samples(output.bytes),
            floatArrayOf(0f, 1f, 16_384f / 32_767f, -0.5f, -1f, 8_192f / 32_767f),
        )
    }

    @Test
    fun int16OutputIsLittleEndianAndInterleaved() {
        val converter = AudioDataConverter(
            sourceSampleRate = 48_000u,
            sourceChannelCount = 2u,
            requestedFormat = AudioDataFormat(sampleFormat = AudioSampleFormat.Int16),
        )

        val output = converter.convert(
            pcmData = shortArrayOf(0, Short.MAX_VALUE, 16_384, -16_384, Short.MIN_VALUE, 8_192),
            frameCount = 3,
            timestampUs = 0,
        )

        assertEquals(AudioSampleFormat.Int16, output.sampleFormat)
        assertEquals(3 * 2 * Short.SIZE_BYTES, output.bytes.size)
        assertArrayEquals(
            shortArrayOf(0, Short.MAX_VALUE, 16_384, -16_384, Short.MIN_VALUE, 8_192),
            int16Samples(output.bytes),
        )
    }

    @Test
    fun monoCanBeMappedToStereo() {
        val converter = AudioDataConverter(
            sourceSampleRate = 48_000u,
            sourceChannelCount = 1u,
            requestedFormat = AudioDataFormat(channelCount = 2u),
        )

        val output = converter.convert(
            pcmData = shortArrayOf(0, Short.MAX_VALUE),
            frameCount = 2,
            timestampUs = 0,
        )

        assertEquals(2u, output.channelCount)
        assertFloatSamples(float32Samples(output.bytes), floatArrayOf(0f, 0f, 1f, 1f))
    }

    @Test
    fun invalidFormatsThrow() {
        assertThrows(IllegalArgumentException::class.java) {
            AudioDataConverter(
                sourceSampleRate = 0u,
                sourceChannelCount = 2u,
                requestedFormat = AudioDataFormat(),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AudioDataConverter(
                sourceSampleRate = 48_000u,
                sourceChannelCount = 2u,
                requestedFormat = AudioDataFormat(sampleRate = 0u),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AudioDataConverter(
                sourceSampleRate = 48_000u,
                sourceChannelCount = 2u,
                requestedFormat = AudioDataFormat(channelCount = 0u),
            )
        }
    }

    private fun float32Samples(bytes: ByteArray): FloatArray {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(bytes.size / Float.SIZE_BYTES) {
            buffer.getFloat()
        }
    }

    private fun int16Samples(bytes: ByteArray): ShortArray {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return ShortArray(bytes.size / Short.SIZE_BYTES) {
            buffer.getShort()
        }
    }

    private fun assertFloatSamples(actual: FloatArray, expected: FloatArray) {
        assertEquals(expected.size, actual.size)
        actual.zip(expected).forEach { (actualSample, expectedSample) ->
            assertEquals(expectedSample.toDouble(), actualSample.toDouble(), 0.000_1)
        }
    }
}
