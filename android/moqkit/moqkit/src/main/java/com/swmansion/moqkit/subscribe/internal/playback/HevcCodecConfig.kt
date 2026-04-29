package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.AnnexBUtils
import java.io.ByteArrayOutputStream

internal object HevcCodecConfig {
    fun csdFromHvcc(description: ByteArray): Map<String, ByteArray> {
        var pos = 22
        if (pos >= description.size) return emptyMap()

        val numArrays = description[pos++].toInt() and 0xFF
        val out = ByteArrayOutputStream()

        repeat(numArrays) {
            if (pos + 3 > description.size) return emptyMap()
            pos++
            val numNalus = readUInt16(description, pos)
            pos += 2
            repeat(numNalus) {
                if (pos + 2 > description.size) return emptyMap()
                val naluLen = readUInt16(description, pos)
                pos += 2
                if (pos + naluLen > description.size) return emptyMap()
                out.write(ANNEX_B_START_CODE)
                out.write(description, pos, naluLen)
                pos += naluLen
            }
        }

        val combined = out.toByteArray()
        return if (combined.isEmpty()) emptyMap() else mapOf("csd-0" to combined)
    }

    fun csdFromAnnexBKeyframe(payload: ByteArray): Map<String, ByteArray>? {
        val csd = AnnexBUtils.extractH265ParameterSets(payload) ?: return null
        return mapOf("csd-0" to csd)
    }
}
