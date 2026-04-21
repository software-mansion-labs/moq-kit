package com.swmansion.moqkit.publish.encoder.internal

internal object AvccConverter {

    fun annexBToAvcc(annexB: ByteArray): ByteArray {
        val out = ArrayList<Byte>(annexB.size)
        var i = 0
        while (i < annexB.size) {
            val scLen = startCodeLength(annexB, i)
            if (scLen == 0) { i++; continue }
            i += scLen
            val end = nextStartCode(annexB, i)
            val naluLen = end - i
            out.add((naluLen ushr 24).toByte())
            out.add((naluLen ushr 16).toByte())
            out.add((naluLen ushr 8).toByte())
            out.add(naluLen.toByte())
            for (k in i until end) out.add(annexB[k])
            i = end
        }
        return out.toByteArray()
    }

    fun buildAvcDecoderConfigurationRecord(sps: ByteArray, pps: ByteArray): ByteArray {
        check(sps.size >= 4) { "SPS too short" }
        val out = ArrayList<Byte>(11 + sps.size + pps.size)
        out.add(1)                           // configurationVersion
        out.add(sps[1])                      // AVCProfileIndication
        out.add(sps[2])                      // profile_compatibility
        out.add(sps[3])                      // AVCLevelIndication
        out.add(0xFF.toByte())               // lengthSizeMinusOne = 3 (4-byte length)
        out.add((0xE0 or 1).toByte())        // numSequenceParameterSets = 1
        out.add((sps.size ushr 8).toByte())
        out.add(sps.size.toByte())
        sps.forEach { out.add(it) }
        out.add(1)                           // numPictureParameterSets = 1
        out.add((pps.size ushr 8).toByte())
        out.add(pps.size.toByte())
        pps.forEach { out.add(it) }
        return out.toByteArray()
    }

    fun extractNalusFromAnnexB(csd: ByteArray): List<ByteArray> {
        val nalus = mutableListOf<ByteArray>()
        var i = 0
        while (i < csd.size) {
            val scLen = startCodeLength(csd, i)
            if (scLen == 0) { i++; continue }
            i += scLen
            val end = nextStartCode(csd, i)
            if (end > i) nalus.add(csd.copyOfRange(i, end))
            i = end
        }
        return nalus
    }

    private fun startCodeLength(buf: ByteArray, i: Int): Int {
        if (i + 3 < buf.size &&
            buf[i] == 0.toByte() && buf[i + 1] == 0.toByte() &&
            buf[i + 2] == 0.toByte() && buf[i + 3] == 1.toByte()
        ) return 4
        if (i + 2 < buf.size &&
            buf[i] == 0.toByte() && buf[i + 1] == 0.toByte() &&
            buf[i + 2] == 1.toByte()
        ) return 3
        return 0
    }

    private fun nextStartCode(buf: ByteArray, from: Int): Int {
        var j = from
        while (j < buf.size) {
            if (startCodeLength(buf, j) > 0) return j
            j++
        }
        return buf.size
    }
}
