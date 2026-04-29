package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.AnnexBUtils

internal object H264CodecConfig {
    fun csdFromAvcc(description: ByteArray): Map<String, ByteArray> {
        var pos = 5
        if (pos >= description.size) return emptyMap()

        val out = mutableMapOf<String, ByteArray>()
        val numSps = description[pos++].toInt() and 0x1F
        if (numSps > 0 && pos + 2 <= description.size) {
            val spsLen = readUInt16(description, pos)
            pos += 2
            if (pos + spsLen <= description.size) {
                out["csd-0"] = H264SpsRewriter.rewriteSps(
                    annexBWrap(description, pos, spsLen),
                )
                pos += spsLen
            }
        }

        if (pos >= description.size) return out
        val numPps = description[pos++].toInt() and 0xFF
        if (numPps > 0 && pos + 2 <= description.size) {
            val ppsLen = readUInt16(description, pos)
            pos += 2
            if (pos + ppsLen <= description.size) {
                out["csd-1"] = annexBWrap(description, pos, ppsLen)
            }
        }
        return out
    }

    fun csdFromAnnexBKeyframe(payload: ByteArray): Map<String, ByteArray>? {
        val params = AnnexBUtils.extractH264ParameterSets(payload) ?: return null
        return mapOf(
            "csd-0" to H264SpsRewriter.rewriteSps(params.sps),
            "csd-1" to params.pps,
        )
    }
}
