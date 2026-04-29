package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.H264SpsParser
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.moq.Container
import uniffi.moq.MoqDimensions
import uniffi.moq.MoqVideo

class VideoPayloadTransformTest {
    @Test
    fun avcWithDescriptionConvertsLengthPrefixedPayloadAndRewritesSps() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2)
        val idr = byteArrayOf(0x65, 0x11, 0x22)
        val payload = lengthPrefixed(sps) + lengthPrefixed(idr)

        val transformed = VideoPayloadTransformBuilder
            .from(videoConfig(codec = "avc1", description = byteArrayOf(1)))
            .apply(payload)

        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(transformed))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22), transformed.takeLast(7).toByteArray())
    }

    @Test
    fun avcWithoutDescriptionRewritesAnnexBSps() {
        val payload = annexB(buildBaselineSps(maxNumReorderFrames = 2)) + annexB(byteArrayOf(0x65, 0x11, 0x22))

        val transformed = VideoPayloadTransformBuilder
            .from(videoConfig(codec = "avc3", description = null))
            .apply(payload)

        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(transformed))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22), transformed.takeLast(7).toByteArray())
    }

    @Test
    fun hevcWithDescriptionConvertsLengthPrefixedPayload() {
        val vps = byteArrayOf(0x40, 0x01)
        val slice = byteArrayOf(0x26, 0x01, 0x7F)
        val payload = lengthPrefixed(vps) + lengthPrefixed(slice)

        val transformed = VideoPayloadTransformBuilder
            .from(videoConfig(codec = "hev1", description = byteArrayOf(1)))
            .apply(payload)

        assertArrayEquals(annexB(vps) + annexB(slice), transformed)
    }

    @Test
    fun av1PayloadsPassThrough() {
        val payload = byteArrayOf(0x12, 0x34, 0x56)

        val transformed = VideoPayloadTransformBuilder
            .from(videoConfig(codec = "av01", description = byteArrayOf(1)))
            .apply(payload)

        assertArrayEquals(payload, transformed)
    }

    private fun videoConfig(codec: String, description: ByteArray?): MoqVideo = MoqVideo(
        codec = codec,
        description = description,
        coded = MoqDimensions(1920u, 1080u),
        displayRatio = null,
        bitrate = null,
        framerate = null,
        container = Container.Legacy,
    )

    private fun lengthPrefixed(nal: ByteArray): ByteArray =
        byteArrayOf(
            (nal.size ushr 24).toByte(),
            (nal.size ushr 16).toByte(),
            (nal.size ushr 8).toByte(),
            nal.size.toByte(),
        ) + nal

    private fun annexB(nal: ByteArray): ByteArray = byteArrayOf(0, 0, 0, 1) + nal

    private fun buildBaselineSps(maxNumReorderFrames: Int): ByteArray {
        val bits = BitWriter()
        bits.writeBits(66, 8)
        bits.writeBits(0, 8)
        bits.writeBits(30, 8)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(1)
        bits.writeBit(false)
        bits.writeUnsignedExpGolomb(19)
        bits.writeUnsignedExpGolomb(14)
        bits.writeBit(true)
        bits.writeBit(true)
        bits.writeBit(false)
        bits.writeBit(true)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(false)
        bits.writeBit(true)
        bits.writeBit(true)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(0)
        bits.writeUnsignedExpGolomb(10)
        bits.writeUnsignedExpGolomb(10)
        bits.writeUnsignedExpGolomb(maxNumReorderFrames)
        bits.writeUnsignedExpGolomb(maxNumReorderFrames + 1)
        return byteArrayOf(0x67) + bits.toRbsp()
    }

    private class BitWriter {
        private val bits = ArrayList<Boolean>()

        fun writeBit(value: Boolean) {
            bits.add(value)
        }

        fun writeBits(value: Int, count: Int) {
            for (i in count - 1 downTo 0) {
                writeBit(((value ushr i) and 1) == 1)
            }
        }

        fun writeUnsignedExpGolomb(value: Int) {
            val codeNum = value + 1
            val bitLength = 32 - Integer.numberOfLeadingZeros(codeNum)
            repeat(bitLength - 1) { writeBit(false) }
            writeBits(codeNum, bitLength)
        }

        fun toRbsp(): ByteArray {
            writeBit(true)
            while (bits.size % 8 != 0) {
                writeBit(false)
            }

            val out = ByteArray(bits.size / 8)
            bits.forEachIndexed { index, bit ->
                if (bit) {
                    out[index / 8] = (out[index / 8].toInt() or (1 shl (7 - index % 8))).toByte()
                }
            }
            return out
        }
    }
}
