package com.swmansion.moqkit.subscribe.internal.codec

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class H264SpsParserTest {
    @Test
    fun parsesMaxNumReorderFramesFromRawSpsNal() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = true)

        assertEquals(2, H264SpsParser.parseMaxNumReorderFrames(sps))
    }

    @Test
    fun parsesMaxNumReorderFramesFromAnnexBWrappedSpsNal() {
        val sps = byteArrayOf(0, 0, 0, 1) +
            buildBaselineSps(maxNumReorderFrames = 3, vuiParametersPresent = true)

        assertEquals(3, H264SpsParser.parseMaxNumReorderFrames(sps))
    }

    @Test
    fun returnsNullWhenVuiIsAbsent() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = false)

        assertNull(H264SpsParser.parseMaxNumReorderFrames(sps))
    }

    @Test
    fun returnsNullWhenSpsIsMalformed() {
        val sps = byteArrayOf(0, 0, 0, 1, 0x67)

        assertNull(H264SpsParser.parseMaxNumReorderFrames(sps))
    }

    @Test
    fun overridesExistingMaxNumReorderFrames() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = true)

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)

        assertNotNull(overridden)
        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(overridden!!))
        assertEquals(1, H264SpsParser.parseBitstreamRestriction(overridden)?.maxDecFrameBuffering)
    }

    @Test
    fun preservesOptimalVuiUnchanged() {
        val sps = buildBaselineSps(
            maxNumReorderFrames = 0,
            maxDecFrameBuffering = 1,
            vuiParametersPresent = true,
            bitstreamDefaults = BitstreamDefaults(
                maxBytesPerPicDenom = 7,
                maxBitsPerMbDenom = 8,
                log2MaxMvLengthHorizontal = 9,
                log2MaxMvLengthVertical = 10,
            ),
            videoSignal = VideoSignal(
                fullRange = true,
                colourPrimaries = 1,
                transferCharacteristics = 1,
                matrixCoefficients = 1,
            ),
        )

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)

        assertNotNull(overridden)
        assertArrayEquals(sps, overridden)
    }

    @Test
    fun overridesAnnexBWrappedSpsNalAndPreservesStartCode() {
        val sps = byteArrayOf(0, 0, 0, 1) +
            buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = true)

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)

        assertNotNull(overridden)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1), overridden!!.copyOfRange(0, 4))
        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(overridden))
    }

    @Test
    fun addsVuiBitstreamRestrictionWhenVuiIsAbsent() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = false)

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)
        val restriction = H264SpsParser.parseBitstreamRestriction(overridden!!)

        assertNotNull(overridden)
        assertEquals(0, restriction?.maxNumReorderFrames)
        assertEquals(1, restriction?.maxDecFrameBuffering)
        assertEquals(2, restriction?.maxBytesPerPicDenom)
        assertEquals(1, restriction?.maxBitsPerMbDenom)
        assertEquals(16, restriction?.log2MaxMvLengthHorizontal)
        assertEquals(16, restriction?.log2MaxMvLengthVertical)
    }

    @Test
    fun addsBitstreamRestrictionWhenVuiIsPresentButRestrictionIsAbsent() {
        val sps = buildBaselineSps(
            maxNumReorderFrames = 2,
            vuiParametersPresent = true,
            bitstreamRestrictionPresent = false,
        )

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)
        val restriction = H264SpsParser.parseBitstreamRestriction(overridden!!)

        assertNull(H264SpsParser.parseMaxNumReorderFrames(sps))
        assertNotNull(overridden)
        assertEquals(0, restriction?.maxNumReorderFrames)
        assertEquals(1, restriction?.maxDecFrameBuffering)
        assertEquals(2, restriction?.maxBytesPerPicDenom)
        assertEquals(1, restriction?.maxBitsPerMbDenom)
        assertEquals(16, restriction?.log2MaxMvLengthHorizontal)
        assertEquals(16, restriction?.log2MaxMvLengthVertical)
    }

    @Test
    fun rewritesMaxDecFrameBufferingWhenReorderFramesAlreadyZero() {
        val sps = buildBaselineSps(
            maxNumReorderFrames = 0,
            maxDecFrameBuffering = 3,
            vuiParametersPresent = true,
        )

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)
        val restriction = H264SpsParser.parseBitstreamRestriction(overridden!!)

        assertNotNull(overridden)
        assertEquals(0, restriction?.maxNumReorderFrames)
        assertEquals(1, restriction?.maxDecFrameBuffering)
    }

    @Test
    fun preservesExistingRestrictionDefaultsWhenRestrictionAlreadyExists() {
        val sps = buildBaselineSps(
            maxNumReorderFrames = 2,
            maxDecFrameBuffering = 4,
            vuiParametersPresent = true,
            bitstreamDefaults = BitstreamDefaults(
                motionVectorsOverPicBoundariesFlag = false,
                maxBytesPerPicDenom = 7,
                maxBitsPerMbDenom = 8,
                log2MaxMvLengthHorizontal = 9,
                log2MaxMvLengthVertical = 10,
            ),
        )

        val overridden = H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0)
        val restriction = H264SpsParser.parseBitstreamRestriction(overridden!!)

        assertNotNull(overridden)
        assertEquals(false, restriction?.motionVectorsOverPicBoundariesFlag)
        assertEquals(7, restriction?.maxBytesPerPicDenom)
        assertEquals(8, restriction?.maxBitsPerMbDenom)
        assertEquals(9, restriction?.log2MaxMvLengthHorizontal)
        assertEquals(10, restriction?.log2MaxMvLengthVertical)
        assertEquals(0, restriction?.maxNumReorderFrames)
        assertEquals(1, restriction?.maxDecFrameBuffering)
    }

    @Test
    fun returnsNullWhenOverridingMalformedSps() {
        val sps = byteArrayOf(0, 0, 0, 1, 0x67)

        assertNull(H264SpsParser.overrideMaxNumReorderFrames(sps, value = 0))
    }

    @Test
    fun replacesInBandAnnexBSpsNalInPayload() {
        val sps = buildBaselineSps(maxNumReorderFrames = 2, vuiParametersPresent = true)
        val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0x11, 0x22)
        val idr = byteArrayOf(0, 0, 0, 1, 0x65, 0x33, 0x44)
        val payload = byteArrayOf(0, 0, 0, 1) + sps + pps + idr

        val overridden = H264SpsParser.overrideMaxNumReorderFramesInAnnexBStream(payload, value = 0)

        assertNotNull(overridden)
        assertEquals(0, H264SpsParser.parseMaxNumReorderFrames(overridden!!))
        assertTrue(overridden.size != payload.size || !overridden.contentEquals(payload))
        assertTrue(overridden.toList().containsAll(pps.toList()))
        assertTrue(overridden.toList().containsAll(idr.toList()))
    }

    private fun buildBaselineSps(
        maxNumReorderFrames: Int,
        vuiParametersPresent: Boolean,
        bitstreamRestrictionPresent: Boolean = true,
        maxNumRefFrames: Int = 1,
        maxDecFrameBuffering: Int = maxNumReorderFrames + 1,
        bitstreamDefaults: BitstreamDefaults = BitstreamDefaults(),
        videoSignal: VideoSignal? = null,
    ): ByteArray {
        val bits = BitWriter()
        bits.writeBits(66, 8) // profile_idc: Baseline
        bits.writeBits(0, 8) // constraint flags + reserved bits
        bits.writeBits(30, 8) // level_idc
        bits.writeUnsignedExpGolomb(0) // seq_parameter_set_id
        bits.writeUnsignedExpGolomb(0) // log2_max_frame_num_minus4
        bits.writeUnsignedExpGolomb(0) // pic_order_cnt_type
        bits.writeUnsignedExpGolomb(0) // log2_max_pic_order_cnt_lsb_minus4
        bits.writeUnsignedExpGolomb(maxNumRefFrames) // max_num_ref_frames
        bits.writeBit(false) // gaps_in_frame_num_value_allowed_flag
        bits.writeUnsignedExpGolomb(19) // pic_width_in_mbs_minus1
        bits.writeUnsignedExpGolomb(14) // pic_height_in_map_units_minus1
        bits.writeBit(true) // frame_mbs_only_flag
        bits.writeBit(true) // direct_8x8_inference_flag
        bits.writeBit(false) // frame_cropping_flag
        bits.writeBit(vuiParametersPresent)

        if (vuiParametersPresent) {
            bits.writeBit(false) // aspect_ratio_info_present_flag
            bits.writeBit(false) // overscan_info_present_flag
            bits.writeBit(videoSignal != null) // video_signal_type_present_flag
            if (videoSignal != null) {
                bits.writeBits(5, 3) // video_format: unspecified
                bits.writeBit(videoSignal.fullRange)
                bits.writeBit(true) // colour_description_present_flag
                bits.writeBits(videoSignal.colourPrimaries, 8)
                bits.writeBits(videoSignal.transferCharacteristics, 8)
                bits.writeBits(videoSignal.matrixCoefficients, 8)
            }
            bits.writeBit(false) // chroma_loc_info_present_flag
            bits.writeBit(false) // timing_info_present_flag
            bits.writeBit(false) // nal_hrd_parameters_present_flag
            bits.writeBit(false) // vcl_hrd_parameters_present_flag
            bits.writeBit(false) // pic_struct_present_flag
            bits.writeBit(bitstreamRestrictionPresent)
            if (bitstreamRestrictionPresent) {
                bits.writeBit(bitstreamDefaults.motionVectorsOverPicBoundariesFlag)
                bits.writeUnsignedExpGolomb(bitstreamDefaults.maxBytesPerPicDenom)
                bits.writeUnsignedExpGolomb(bitstreamDefaults.maxBitsPerMbDenom)
                bits.writeUnsignedExpGolomb(bitstreamDefaults.log2MaxMvLengthHorizontal)
                bits.writeUnsignedExpGolomb(bitstreamDefaults.log2MaxMvLengthVertical)
                bits.writeUnsignedExpGolomb(maxNumReorderFrames)
                bits.writeUnsignedExpGolomb(maxDecFrameBuffering)
            }
        }

        return byteArrayOf(0x67) + bits.toRbsp()
    }

    private data class BitstreamDefaults(
        val motionVectorsOverPicBoundariesFlag: Boolean = true,
        val maxBytesPerPicDenom: Int = 0,
        val maxBitsPerMbDenom: Int = 0,
        val log2MaxMvLengthHorizontal: Int = 10,
        val log2MaxMvLengthVertical: Int = 10,
    )

    private data class VideoSignal(
        val fullRange: Boolean,
        val colourPrimaries: Int,
        val transferCharacteristics: Int,
        val matrixCoefficients: Int,
    )

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
