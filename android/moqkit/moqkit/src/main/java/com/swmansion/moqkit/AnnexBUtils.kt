package com.swmansion.moqkit

/**
 * Stateless utilities for scanning Annex B bitstreams and extracting H.264 parameter sets.
 */
internal object AnnexBUtils {

    data class ParameterSets(val sps: ByteArray, val pps: ByteArray)

    /**
     * Scan an Annex B payload for the first SPS (NAL type 7) and first PPS (NAL type 8).
     * Each returned array includes the 4-byte start code prefix (00 00 00 01).
     * Returns null if either SPS or PPS is missing.
     */
    fun extractParameterSets(data: ByteArray): ParameterSets? {
        val nalUnits = findNalUnits(data)
        var sps: ByteArray? = null
        var pps: ByteArray? = null

        for ((offset, length) in nalUnits) {
            if (length == 0) continue
            val nalType = data[offset].toInt() and 0x1F
            when (nalType) {
                7 -> if (sps == null) {
                    sps = ByteArray(4 + length).also {
                        it[3] = 1
                        System.arraycopy(data, offset, it, 4, length)
                    }
                }
                8 -> if (pps == null) {
                    pps = ByteArray(4 + length).also {
                        it[3] = 1
                        System.arraycopy(data, offset, it, 4, length)
                    }
                }
            }
            if (sps != null && pps != null) break
        }

        return if (sps != null && pps != null) ParameterSets(sps, pps) else null
    }

    /**
     * Find all NAL unit boundaries in an Annex B stream.
     * Returns list of (bodyOffset, bodyLength) pairs — bodyOffset points past the start code
     * to the first byte of the NAL unit (the NAL header byte).
     */
    private fun findNalUnits(data: ByteArray): List<Pair<Int, Int>> {
        val units = mutableListOf<Pair<Int, Int>>() // (start, length) — filled in retroactively
        var i = 0
        var currentStart = -1

        while (i < data.size) {
            // Look for 00 00 01 or 00 00 00 01
            if (i + 2 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()
            ) {
                if (currentStart >= 0) {
                    units.add(currentStart to (i - currentStart))
                }
                currentStart = i + 3
                i += 3
            } else if (i + 3 < data.size &&
                data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()
            ) {
                if (currentStart >= 0) {
                    units.add(currentStart to (i - currentStart))
                }
                currentStart = i + 4
                i += 4
            } else {
                i++
            }
        }

        if (currentStart >= 0 && currentStart < data.size) {
            units.add(currentStart to (data.size - currentStart))
        }

        return units
    }
}
