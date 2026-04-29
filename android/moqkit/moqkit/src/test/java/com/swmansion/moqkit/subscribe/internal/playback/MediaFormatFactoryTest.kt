package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.H264SpsParser
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.moq.Container
import uniffi.moq.MoqAudio
import uniffi.moq.MoqDimensions
import uniffi.moq.MoqVideo
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MediaFormatFactoryTest {
    @Test
    fun avcDescriptionBuildsVideoSpecWithRewrittenSpsAndPps() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2)
        val pps = byteArrayOf(0x68, 0x11, 0x22)
        val config = videoConfig(
            codec = "avc1",
            description = buildAvcc(sps, pps),
            width = 1280,
            height = 720,
        )

        val spec = VideoFormatSpecBuilder.fromDescription(config)

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_AVC, spec!!.mime)
        assertEquals(1280, spec.width)
        assertEquals(720, spec.height)
        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(spec.csdBuffers["csd-0"]!!))
        assertArrayEquals(byteArrayOf(0, 0, 0, 1) + pps, spec.csdBuffers["csd-1"]!!)
    }

    @Test
    fun malformedAvcDescriptionDoesNotCrashAndKeepsEmptyCsd() {
        val config = videoConfig(codec = "avc1", description = byteArrayOf(1, 2, 3))

        val spec = VideoFormatSpecBuilder.fromDescription(config)

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_AVC, spec!!.mime)
        assertEquals(emptySet<String>(), spec.csdBuffers.keys)
    }

    @Test
    fun hevcDescriptionCombinesParameterSetsIntoSingleAnnexBCsd() {
        val vps = byteArrayOf(0x40, 0x01)
        val sps = byteArrayOf(0x42, 0x02)
        val pps = byteArrayOf(0x44, 0x03)
        val config = videoConfig(codec = "hev1", description = buildHvcc(vps, sps, pps))

        val spec = VideoFormatSpecBuilder.fromDescription(config)

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_HEVC, spec!!.mime)
        assertArrayEquals(
            byteArrayOf(0, 0, 0, 1) + vps +
                byteArrayOf(0, 0, 0, 1) + sps +
                byteArrayOf(0, 0, 0, 1) + pps,
            spec.csdBuffers["csd-0"]!!,
        )
    }

    @Test
    fun av1DescriptionMapsDirectlyToCsd() {
        val description = byteArrayOf(0x81.toByte(), 0x00, 0x0C, 0x00)
        val config = videoConfig(codec = "av01.0.04M.08", description = description)

        val spec = VideoFormatSpecBuilder.fromDescription(config)

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_AV1, spec!!.mime)
        assertArrayEquals(description, spec.csdBuffers["csd-0"]!!)
    }

    @Test
    fun inBandAvcKeyframeBuildsCsdSpec() {
        val sps = byteArrayOf(0, 0, 0, 1) + buildBaselineSps(maxNumReorderFrames = 2)
        val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0x11, 0x22)
        val idr = byteArrayOf(0, 0, 0, 1, 0x65, 0x33, 0x44)

        val spec = VideoFormatSpecBuilder.fromInBandKeyframe(
            videoConfig(codec = "avc3", description = null),
            sps + pps + idr,
        )

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_AVC, spec!!.mime)
        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(spec.csdBuffers["csd-0"]!!))
        assertArrayEquals(pps, spec.csdBuffers["csd-1"]!!)
    }

    @Test
    fun inBandHevcKeyframeBuildsCsdSpec() {
        val vps = byteArrayOf(0, 0, 0, 1, 0x40, 0x01)
        val sps = byteArrayOf(0, 0, 0, 1, 0x42, 0x02)
        val pps = byteArrayOf(0, 0, 0, 1, 0x44, 0x03)

        val spec = VideoFormatSpecBuilder.fromInBandKeyframe(
            videoConfig(codec = "hev1", description = null),
            vps + sps + pps,
        )

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_HEVC, spec!!.mime)
        assertArrayEquals(vps + sps + pps, spec.csdBuffers["csd-0"]!!)
    }

    @Test
    fun inBandAv1KeyframeBuildsMinimalAv1c() {
        val sequenceHeader = byteArrayOf(0x0A, 0x01, 0x20)

        val spec = VideoFormatSpecBuilder.fromInBandKeyframe(
            videoConfig(codec = "av01", description = null),
            sequenceHeader,
        )

        assertNotNull(spec)
        assertEquals(CodecMime.VIDEO_AV1, spec!!.mime)
        assertArrayEquals(
            byteArrayOf(0x81.toByte(), 0x20, 0x0C, 0x00) + sequenceHeader,
            spec.csdBuffers["csd-0"]!!,
        )
    }

    @Test
    fun unsupportedVideoCodecReturnsNull() {
        assertNull(VideoFormatSpecBuilder.fromDescription(videoConfig(codec = "vp09", description = byteArrayOf(1))))
        assertNull(VideoFormatSpecBuilder.fromInBandKeyframe(videoConfig(codec = "vp09", description = null), byteArrayOf(1)))
    }

    @Test
    fun aacUsesProvidedDescriptionOrGeneratedAudioSpecificConfig() {
        val provided = byteArrayOf(0x12, 0x10)
        val withDescription = AudioFormatSpecBuilder.from(audioConfig("mp4a.40.2", description = provided))
        val generated = AudioFormatSpecBuilder.from(audioConfig("aac", description = null))

        assertNotNull(withDescription)
        assertEquals(CodecMime.AUDIO_AAC, withDescription!!.mime)
        assertArrayEquals(provided, withDescription.csdBuffers["csd-0"]!!)
        assertNotNull(generated)
        assertArrayEquals(byteArrayOf(0x11, 0x90.toByte()), generated!!.csdBuffers["csd-0"]!!)
    }

    @Test
    fun opusUsesHeaderAndBuildsDelayBuffers() {
        val header = OpusCodecConfig.buildIdentificationHeader(sampleRate = 48_000, channelCount = 2)

        val spec = AudioFormatSpecBuilder.from(audioConfig("opus", description = header))

        assertNotNull(spec)
        assertEquals(CodecMime.AUDIO_OPUS, spec!!.mime)
        assertArrayEquals(header, spec.csdBuffers["csd-0"]!!)
        assertEquals(6_500_000L, spec.csdBuffers["csd-1"]!!.littleEndianLong())
        assertEquals(80_000_000L, spec.csdBuffers["csd-2"]!!.littleEndianLong())
    }

    @Test
    fun unsupportedAudioCodecReturnsNull() {
        assertNull(AudioFormatSpecBuilder.from(audioConfig("flac", description = null)))
    }

    private fun videoConfig(
        codec: String,
        description: ByteArray?,
        width: Int = 1920,
        height: Int = 1080,
    ): MoqVideo = MoqVideo(
        codec = codec,
        description = description,
        coded = MoqDimensions(width.toUInt(), height.toUInt()),
        displayRatio = null,
        bitrate = null,
        framerate = null,
        container = Container.Legacy,
    )

    private fun audioConfig(codec: String, description: ByteArray?): MoqAudio = MoqAudio(
        codec = codec,
        description = description,
        sampleRate = 48_000u,
        channelCount = 2u,
        bitrate = null,
        container = Container.Legacy,
    )

    private fun buildAvcc(sps: ByteArray, pps: ByteArray): ByteArray {
        return byteArrayOf(
            1,
            sps[1],
            sps[2],
            sps[3],
            0xFF.toByte(),
            0xE1.toByte(),
        ) + sps.size.u16() + sps + byteArrayOf(1) + pps.size.u16() + pps
    }

    private fun buildHvcc(vps: ByteArray, sps: ByteArray, pps: ByteArray): ByteArray {
        val header = ByteArray(22)
        return header + byteArrayOf(3) +
            buildHvccArray(32, vps) +
            buildHvccArray(33, sps) +
            buildHvccArray(34, pps)
    }

    private fun buildHvccArray(nalType: Int, nalu: ByteArray): ByteArray {
        return byteArrayOf(nalType.toByte()) + 1.u16() + nalu.size.u16() + nalu
    }

    private fun Int.u16(): ByteArray = byteArrayOf((this ushr 8).toByte(), this.toByte())

    private fun ByteArray.littleEndianLong(): Long =
        ByteBuffer.wrap(this).order(ByteOrder.LITTLE_ENDIAN).long

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
