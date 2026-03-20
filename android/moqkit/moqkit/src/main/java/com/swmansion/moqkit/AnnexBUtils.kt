package com.swmansion.moqkit

import java.io.ByteArrayOutputStream

/**
 * Stateless utilities for scanning Annex B bitstreams and extracting codec parameter sets.
 *
 * Layer 1: [findNalUnits] — lazy NAL unit scanner shared by all codecs.
 * Layer 2: [extractH264ParameterSets] / [extractH265ParameterSets] — codec-specific extractors.
 */
internal object AnnexBUtils {

    data class NalUnit(val offset: Int, val length: Int)

    data class H264ParameterSets(val sps: ByteArray, val pps: ByteArray)

    /**
     * Lazily yields [NalUnit] entries for each NAL unit in an Annex B stream.
     * [NalUnit.offset] points past the start code to the first byte of the NAL header.
     * Recognises both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes.
     */
    fun findNalUnits(data: ByteArray): Sequence<NalUnit> = sequence {
        var i = 0
        var currentStart = -1

        while (i < data.size) {
            if (i + 2 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()
            ) {
                if (currentStart >= 0) {
                    yield(NalUnit(currentStart, i - currentStart))
                }
                currentStart = i + 3
                i += 3
            } else if (i + 3 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()
            ) {
                if (currentStart >= 0) {
                    yield(NalUnit(currentStart, i - currentStart))
                }
                currentStart = i + 4
                i += 4
            } else {
                i++
            }
        }

        if (currentStart >= 0 && currentStart < data.size) {
            yield(NalUnit(currentStart, data.size - currentStart))
        }
    }

    /**
     * Extract first SPS (NAL type 7) + PPS (NAL type 8) from an Annex B H.264 stream.
     * Each returned array includes the 4-byte start code prefix (00 00 00 01).
     * Returns null if either SPS or PPS is missing.
     */
    fun extractH264ParameterSets(data: ByteArray): H264ParameterSets? {
        var sps: ByteArray? = null
        var pps: ByteArray? = null

        for (nal in findNalUnits(data)) {
            if (nal.length == 0) continue
            val nalType = data[nal.offset].toInt() and 0x1F
            when (nalType) {
                7 -> if (sps == null) {
                    sps = annexBWrap(data, nal.offset, nal.length)
                }
                8 -> if (pps == null) {
                    pps = annexBWrap(data, nal.offset, nal.length)
                }
            }
            if (sps != null && pps != null) break
        }

        return if (sps != null && pps != null) H264ParameterSets(sps, pps) else null
    }

    /**
     * Extract VPS (NAL type 32) + SPS (33) + PPS (34) from an Annex B H.265 stream.
     * Returns a single combined byte array with start code prefixes (matching [parseHvcc] output),
     * or null if any of the three parameter sets is missing.
     */
    fun extractH265ParameterSets(data: ByteArray): ByteArray? {
        var vps: ByteArray? = null
        var sps: ByteArray? = null
        var pps: ByteArray? = null

        for (nal in findNalUnits(data)) {
            if (nal.length < 2) continue // HEVC NAL header is 2 bytes
            val nalType = (data[nal.offset].toInt() ushr 1) and 0x3F
            when (nalType) {
                32 -> if (vps == null) vps = annexBWrap(data, nal.offset, nal.length)
                33 -> if (sps == null) sps = annexBWrap(data, nal.offset, nal.length)
                34 -> if (pps == null) pps = annexBWrap(data, nal.offset, nal.length)
            }
            if (vps != null && sps != null && pps != null) break
        }

        if (vps == null || sps == null || pps == null) return null

        val out = ByteArrayOutputStream(vps.size + sps.size + pps.size)
        out.write(vps)
        out.write(sps)
        out.write(pps)
        return out.toByteArray()
    }

    private fun annexBWrap(src: ByteArray, offset: Int, length: Int): ByteArray {
        val buf = ByteArray(4 + length)
        buf[3] = 1
        System.arraycopy(src, offset, buf, 4, length)
        return buf
    }
}

// Convert AVCC/HVCC frame payload (4-byte big-endian NAL length prefix per NAL unit)
// to Annex B format (0x00 0x00 0x00 0x01 start codes) required by MediaCodec.
// Works for both H.264 and HEVC (both use 4-byte length-prefixed NALUs).
internal fun ByteArray.prefixLengthToAnnexB(): ByteArray {
    val out = ByteArrayOutputStream(size)
    var pos = 0
    while (pos + 4 <= size) {
        val nalLen = ((this[pos].toInt() and 0xFF) shl 24) or
            ((this[pos + 1].toInt() and 0xFF) shl 16) or
            ((this[pos + 2].toInt() and 0xFF) shl 8) or
            (this[pos + 3].toInt() and 0xFF)
        pos += 4
        if (pos + nalLen > size) break
        out.write(byteArrayOf(0, 0, 0, 1))
        out.write(this, pos, nalLen)
        pos += nalLen
    }
    return out.toByteArray()
}
