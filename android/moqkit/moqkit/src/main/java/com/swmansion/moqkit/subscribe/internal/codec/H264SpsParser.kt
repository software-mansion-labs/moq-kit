package com.swmansion.moqkit.subscribe.internal.codec

import java.io.ByteArrayOutputStream

internal object H264SpsParser {
    data class BitstreamRestriction(
        val motionVectorsOverPicBoundariesFlag: Boolean,
        val maxBytesPerPicDenom: Int,
        val maxBitsPerMbDenom: Int,
        val log2MaxMvLengthHorizontal: Int,
        val log2MaxMvLengthVertical: Int,
        val maxNumReorderFrames: Int,
        val maxDecFrameBuffering: Int,
    )

    fun parseMaxNumReorderFrames(sps: ByteArray): Int? {
        return try {
            val nal = findSpsNal(sps) ?: return null
            parseSps(nal.nal).maxNumReorderFrames
        } catch (_: RuntimeException) {
            null
        }
    }

    fun parseBitstreamRestriction(sps: ByteArray): BitstreamRestriction? {
        return try {
            val nal = findSpsNal(sps) ?: return null
            parseSps(nal.nal).bitstreamRestriction
        } catch (_: RuntimeException) {
            null
        }
    }

    fun overrideMaxNumReorderFrames(sps: ByteArray, value: Int): ByteArray? {
        require(value >= 0) { "max_num_reorder_frames must be non-negative" }
        return try {
            val nal = findSpsNal(sps) ?: return null
            val parsed = parseSps(nal.nal)
            if (parsed.isRestrictionOptimal(value)) {
                return sps
            }
            val patchedRbsp = patchRbsp(parsed, value)
            val rewrittenNal = byteArrayOf(nal.nal[0]) + addEmulationPreventionBytes(patchedRbsp)
            sps.copyOfRange(0, nal.offset) + rewrittenNal +
                sps.copyOfRange(nal.offset + nal.length, sps.size)
        } catch (_: RuntimeException) {
            null
        }
    }

    fun overrideMaxNumReorderFramesInAnnexBStream(data: ByteArray, value: Int): ByteArray? {
        require(value >= 0) { "max_num_reorder_frames must be non-negative" }
        return try {
            val out = ByteArrayOutputStream(data.size)
            var cursor = 0
            var replaced = false

            for (nal in AnnexBUtils.findNalUnits(data)) {
                if (nal.length == 0 || (data[nal.offset].toInt() and 0x1F) != SPS_NAL_TYPE) {
                    continue
                }

                out.write(data, cursor, nal.offset - cursor)
                val originalNal = data.copyOfRange(nal.offset, nal.offset + nal.length)
                val patchedNal = overrideMaxNumReorderFrames(originalNal, value) ?: originalNal
                out.write(patchedNal)
                cursor = nal.offset + nal.length
                replaced = true
            }

            if (!replaced) return data
            out.write(data, cursor, data.size - cursor)
            out.toByteArray()
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun parseSps(nal: ByteArray): SpsInfo {
        if (nal.isEmpty()) throw IllegalArgumentException("empty SPS")

        val rbsp = removeEmulationPreventionBytes(nal, 1, nal.size - 1)
        val bits = BitReader(rbsp)

        val profileIdc = bits.readBits(8)
        bits.readBits(8) // constraint flags + reserved bits
        bits.readBits(8) // level_idc
        bits.readUnsignedExpGolomb() // seq_parameter_set_id

        if (profileIdc in HIGH_PROFILE_IDS) {
            val chromaFormatIdc = bits.readUnsignedExpGolomb()
            if (chromaFormatIdc == 3) {
                bits.readBit() // separate_colour_plane_flag
            }
            bits.readUnsignedExpGolomb() // bit_depth_luma_minus8
            bits.readUnsignedExpGolomb() // bit_depth_chroma_minus8
            bits.readBit() // qpprime_y_zero_transform_bypass_flag
            if (bits.readBit()) {
                val scalingListCount = if (chromaFormatIdc != 3) 8 else 12
                repeat(scalingListCount) { index ->
                    if (bits.readBit()) {
                        skipScalingList(bits, if (index < 6) 16 else 64)
                    }
                }
            }
        }

        bits.readUnsignedExpGolomb() // log2_max_frame_num_minus4
        when (bits.readUnsignedExpGolomb()) { // pic_order_cnt_type
            0 -> bits.readUnsignedExpGolomb() // log2_max_pic_order_cnt_lsb_minus4
            1 -> {
                bits.readBit() // delta_pic_order_always_zero_flag
                bits.readSignedExpGolomb() // offset_for_non_ref_pic
                bits.readSignedExpGolomb() // offset_for_top_to_bottom_field
                repeat(bits.readUnsignedExpGolomb()) {
                    bits.readSignedExpGolomb() // offset_for_ref_frame[i]
                }
            }
        }

        val maxNumRefFrames = bits.readUnsignedExpGolomb()
        bits.readBit() // gaps_in_frame_num_value_allowed_flag
        bits.readUnsignedExpGolomb() // pic_width_in_mbs_minus1
        bits.readUnsignedExpGolomb() // pic_height_in_map_units_minus1
        val frameMbsOnlyFlag = bits.readBit()
        if (!frameMbsOnlyFlag) {
            bits.readBit() // mb_adaptive_frame_field_flag
        }
        bits.readBit() // direct_8x8_inference_flag
        if (bits.readBit()) {
            bits.readUnsignedExpGolomb() // frame_crop_left_offset
            bits.readUnsignedExpGolomb() // frame_crop_right_offset
            bits.readUnsignedExpGolomb() // frame_crop_top_offset
            bits.readUnsignedExpGolomb() // frame_crop_bottom_offset
        }

        val vuiFlagOffset = bits.position
        if (!bits.readBit()) {
            return SpsInfo(
                rbsp = rbsp,
                maxNumRefFrames = maxNumRefFrames,
                vuiFlagRange = BitRange(vuiFlagOffset, bits.position),
            )
        }

        return parseVui(bits, rbsp, maxNumRefFrames, vuiFlagOffset)
    }

    private fun parseVui(
        bits: BitReader,
        rbsp: ByteArray,
        maxNumRefFrames: Int,
        vuiFlagOffset: Int,
    ): SpsInfo {
        if (bits.readBit()) {
            val aspectRatioIdc = bits.readBits(8)
            if (aspectRatioIdc == EXTENDED_SAR) {
                bits.readBits(16) // sar_width
                bits.readBits(16) // sar_height
            }
        }
        if (bits.readBit()) {
            bits.readBit() // overscan_appropriate_flag
        }
        if (bits.readBit()) {
            bits.readBits(3) // video_format
            bits.readBit() // video_full_range_flag
            if (bits.readBit()) {
                bits.readBits(8) // colour_primaries
                bits.readBits(8) // transfer_characteristics
                bits.readBits(8) // matrix_coefficients
            }
        }
        if (bits.readBit()) {
            bits.readUnsignedExpGolomb() // chroma_sample_loc_type_top_field
            bits.readUnsignedExpGolomb() // chroma_sample_loc_type_bottom_field
        }
        if (bits.readBit()) {
            bits.readBits(32) // num_units_in_tick
            bits.readBits(32) // time_scale
            bits.readBit() // fixed_frame_rate_flag
        }
        val nalHrdParametersPresent = bits.readBit()
        if (nalHrdParametersPresent) {
            skipHrdParameters(bits)
        }
        val vclHrdParametersPresent = bits.readBit()
        if (vclHrdParametersPresent) {
            skipHrdParameters(bits)
        }
        if (nalHrdParametersPresent || vclHrdParametersPresent) {
            bits.readBit() // low_delay_hrd_flag
        }
        bits.readBit() // pic_struct_present_flag

        val restrictionFlagOffset = bits.position
        if (!bits.readBit()) {
            return SpsInfo(
                rbsp = rbsp,
                maxNumRefFrames = maxNumRefFrames,
                vuiFlagRange = BitRange(vuiFlagOffset, vuiFlagOffset + 1),
                bitstreamRestrictionFlagRange = BitRange(restrictionFlagOffset, bits.position),
            )
        }

        val motionVectorsOverPicBoundariesFlag = bits.readBit()
        val maxBytesPerPicDenom = bits.readUnsignedExpGolomb()
        val maxBitsPerMbDenom = bits.readUnsignedExpGolomb()
        val log2MaxMvLengthHorizontal = bits.readUnsignedExpGolomb()
        val log2MaxMvLengthVertical = bits.readUnsignedExpGolomb()
        val reorderingLimitsStart = bits.position
        val maxNumReorderFrames = bits.readUnsignedExpGolomb()
        val maxDecFrameBuffering = bits.readUnsignedExpGolomb()
        val reorderingLimitsEnd = bits.position
        val bitstreamRestriction = BitstreamRestriction(
            motionVectorsOverPicBoundariesFlag = motionVectorsOverPicBoundariesFlag,
            maxBytesPerPicDenom = maxBytesPerPicDenom,
            maxBitsPerMbDenom = maxBitsPerMbDenom,
            log2MaxMvLengthHorizontal = log2MaxMvLengthHorizontal,
            log2MaxMvLengthVertical = log2MaxMvLengthVertical,
            maxNumReorderFrames = maxNumReorderFrames,
            maxDecFrameBuffering = maxDecFrameBuffering,
        )

        return SpsInfo(
            rbsp = rbsp,
            maxNumRefFrames = maxNumRefFrames,
            vuiFlagRange = BitRange(vuiFlagOffset, vuiFlagOffset + 1),
            bitstreamRestrictionFlagRange = BitRange(restrictionFlagOffset, restrictionFlagOffset + 1),
            maxNumReorderFrames = bitstreamRestriction.maxNumReorderFrames,
            maxDecFrameBuffering = bitstreamRestriction.maxDecFrameBuffering,
            reorderingLimitsRange = BitRange(reorderingLimitsStart, reorderingLimitsEnd),
            bitstreamRestriction = bitstreamRestriction,
        )
    }

    private fun patchRbsp(info: SpsInfo, value: Int): ByteArray {
        val rbspBits = info.rbsp.toBits()
        val replacement = when {
            info.reorderingLimitsRange != null -> {
                BitReplacement(
                    info.reorderingLimitsRange,
                    unsignedExpGolombBits(value) + unsignedExpGolombBits(info.maxNumRefFrames),
                )
            }
            info.bitstreamRestrictionFlagRange != null -> {
                BitReplacement(
                    info.bitstreamRestrictionFlagRange,
                    listOf(true) + bitstreamRestrictionBits(value, info.maxNumRefFrames),
                )
            }
            else -> {
                BitReplacement(
                    info.vuiFlagRange,
                    listOf(true) + minimalVuiBits(value, info.maxNumRefFrames),
                )
            }
        }

        val out = ArrayList<Boolean>(
            rbspBits.size - replacement.range.length + replacement.bits.size,
        )
        out.addAll(rbspBits.subList(0, replacement.range.start))
        out.addAll(replacement.bits)
        out.addAll(rbspBits.subList(replacement.range.end, rbspBits.size))
        return out.toByteArrayPadded()
    }

    private fun minimalVuiBits(value: Int, maxNumRefFrames: Int): List<Boolean> {
        val bits = ArrayList<Boolean>()
        bits.add(false) // aspect_ratio_info_present_flag
        bits.add(false) // overscan_info_present_flag
        bits.add(false) // video_signal_type_present_flag
        bits.add(false) // chroma_loc_info_present_flag
        bits.add(false) // timing_info_present_flag
        bits.add(false) // nal_hrd_parameters_present_flag
        bits.add(false) // vcl_hrd_parameters_present_flag
        bits.add(false) // pic_struct_present_flag
        bits.add(true) // bitstream_restriction_flag
        bits.addAll(bitstreamRestrictionBits(value, maxNumRefFrames))
        return bits
    }

    private fun bitstreamRestrictionBits(value: Int, maxNumRefFrames: Int): List<Boolean> {
        val bits = ArrayList<Boolean>()
        bits.add(true) // motion_vectors_over_pic_boundaries_flag
        bits.addAll(unsignedExpGolombBits(2)) // max_bytes_per_pic_denom
        bits.addAll(unsignedExpGolombBits(1)) // max_bits_per_mb_denom
        bits.addAll(unsignedExpGolombBits(16)) // log2_max_mv_length_horizontal
        bits.addAll(unsignedExpGolombBits(16)) // log2_max_mv_length_vertical
        bits.addAll(unsignedExpGolombBits(value))
        bits.addAll(unsignedExpGolombBits(maxNumRefFrames)) // max_dec_frame_buffering
        return bits
    }

    private fun skipHrdParameters(bits: BitReader) {
        val cpbCountMinus1 = bits.readUnsignedExpGolomb()
        bits.readBits(4) // bit_rate_scale
        bits.readBits(4) // cpb_size_scale
        repeat(cpbCountMinus1 + 1) {
            bits.readUnsignedExpGolomb() // bit_rate_value_minus1
            bits.readUnsignedExpGolomb() // cpb_size_value_minus1
            bits.readBit() // cbr_flag
        }
        bits.readBits(5) // initial_cpb_removal_delay_length_minus1
        bits.readBits(5) // cpb_removal_delay_length_minus1
        bits.readBits(5) // dpb_output_delay_length_minus1
        bits.readBits(5) // time_offset_length
    }

    private fun skipScalingList(bits: BitReader, size: Int) {
        var lastScale = 8
        var nextScale = 8
        repeat(size) {
            if (nextScale != 0) {
                val deltaScale = bits.readSignedExpGolomb()
                nextScale = (lastScale + deltaScale + 256) % 256
            }
            if (nextScale != 0) {
                lastScale = nextScale
            }
        }
    }

    private fun findSpsNal(data: ByteArray): LocatedNal? {
        val annexBNal = AnnexBUtils.findNalUnits(data)
            .firstOrNull { it.length > 0 && (data[it.offset].toInt() and 0x1F) == SPS_NAL_TYPE }
        if (annexBNal != null) {
            return LocatedNal(
                offset = annexBNal.offset,
                length = annexBNal.length,
                nal = data.copyOfRange(annexBNal.offset, annexBNal.offset + annexBNal.length),
            )
        }

        return if (data.isNotEmpty() && (data[0].toInt() and 0x1F) == SPS_NAL_TYPE) {
            LocatedNal(offset = 0, length = data.size, nal = data)
        } else null
    }

    private fun removeEmulationPreventionBytes(data: ByteArray, offset: Int, length: Int): ByteArray {
        val out = ArrayList<Byte>(length)
        val end = offset + length
        var i = offset
        var zeroCount = 0
        while (i < end) {
            val value = data[i]
            if (zeroCount >= 2 && value == 0x03.toByte()) {
                zeroCount = 0
                i++
                continue
            }

            out.add(value)
            zeroCount = if (value == 0.toByte()) zeroCount + 1 else 0
            i++
        }
        return out.toByteArray()
    }

    private fun addEmulationPreventionBytes(rbsp: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(rbsp.size)
        var zeroCount = 0
        rbsp.forEach { value ->
            if (zeroCount >= 2 && (value.toInt() and 0xFF) <= 0x03) {
                out.write(0x03)
                zeroCount = 0
            }
            out.write(value.toInt())
            zeroCount = if (value == 0.toByte()) zeroCount + 1 else 0
        }
        return out.toByteArray()
    }

    private fun ByteArray.toBits(): List<Boolean> {
        val bits = ArrayList<Boolean>(size * 8)
        forEach { byte ->
            for (i in 7 downTo 0) {
                bits.add(((byte.toInt() ushr i) and 1) == 1)
            }
        }
        return bits
    }

    private fun List<Boolean>.toByteArrayPadded(): ByteArray {
        val padded = ArrayList<Boolean>(size + 7)
        padded.addAll(this)
        while (padded.size % 8 != 0) {
            padded.add(false)
        }

        val out = ByteArray(padded.size / 8)
        padded.forEachIndexed { index, bit ->
            if (bit) {
                out[index / 8] = (out[index / 8].toInt() or (1 shl (7 - index % 8))).toByte()
            }
        }
        return out
    }

    private fun unsignedExpGolombBits(value: Int): List<Boolean> {
        require(value >= 0) { "Exp-Golomb value must be non-negative" }
        val codeNum = value + 1
        val bitLength = 32 - Integer.numberOfLeadingZeros(codeNum)
        val bits = ArrayList<Boolean>(bitLength * 2 - 1)
        repeat(bitLength - 1) { bits.add(false) }
        for (i in bitLength - 1 downTo 0) {
            bits.add(((codeNum ushr i) and 1) == 1)
        }
        return bits
    }

    private class BitReader(private val data: ByteArray) {
        var position = 0
            private set

        fun readBit(): Boolean = readBits(1) == 1

        fun readBits(count: Int): Int {
            require(count in 0..32)
            if (position + count > data.size * 8) {
                throw IllegalArgumentException("Not enough bits")
            }

            var value = 0
            repeat(count) {
                val byteIndex = position / 8
                val bitIndex = 7 - (position % 8)
                value = (value shl 1) or ((data[byteIndex].toInt() ushr bitIndex) and 1)
                position++
            }
            return value
        }

        fun readUnsignedExpGolomb(): Int {
            var leadingZeroBits = 0
            while (!readBit()) {
                leadingZeroBits++
                if (leadingZeroBits > 30) {
                    throw IllegalArgumentException("Exp-Golomb value is too large")
                }
            }
            if (leadingZeroBits == 0) return 0
            return (1 shl leadingZeroBits) - 1 + readBits(leadingZeroBits)
        }

        fun readSignedExpGolomb(): Int {
            val codeNum = readUnsignedExpGolomb()
            val sign = if (codeNum % 2 == 0) -1 else 1
            return sign * ((codeNum + 1) / 2)
        }
    }

    private data class LocatedNal(
        val offset: Int,
        val length: Int,
        val nal: ByteArray,
    )

    private data class SpsInfo(
        val rbsp: ByteArray,
        val maxNumRefFrames: Int,
        val vuiFlagRange: BitRange,
        val bitstreamRestrictionFlagRange: BitRange? = null,
        val maxNumReorderFrames: Int? = null,
        val maxDecFrameBuffering: Int? = null,
        val reorderingLimitsRange: BitRange? = null,
        val bitstreamRestriction: BitstreamRestriction? = null,
    ) {
        fun isRestrictionOptimal(maxNumReorderFramesOverride: Int): Boolean {
            return maxNumReorderFrames == maxNumReorderFramesOverride &&
                maxDecFrameBuffering != null &&
                maxDecFrameBuffering <= maxNumRefFrames
        }
    }

    private data class BitRange(val start: Int, val end: Int) {
        val length: Int get() = end - start
    }

    private data class BitReplacement(
        val range: BitRange,
        val bits: List<Boolean>,
    )

    private const val SPS_NAL_TYPE = 7
    private const val EXTENDED_SAR = 255
    private val HIGH_PROFILE_IDS = setOf(
        100,
        110,
        122,
        244,
        44,
        83,
        86,
        118,
        128,
        138,
        139,
        134,
    )
}
