package com.swmansion.moqkit.subscribe.internal.codec

internal object AV1Utils {
    /**
     * Scan an AV1 OBU stream and return the raw bytes (header + body) of the first
     * Sequence Header OBU (type 1), or null if none is found.
     */
    fun extractSequenceHeader(payload: ByteArray): ByteArray? {
        var offset = 0

        while (offset < payload.size) {
            val headerStart = offset

            val headerByte = payload[offset].toInt() and 0xFF
            offset += 1

            val obuType = (headerByte shr 3) and 0xF
            val extensionFlag = (headerByte shr 2) and 0x1
            val hasSizeField = (headerByte shr 1) and 0x1

            // Skip optional extension header byte
            if (extensionFlag != 0) {
                if (offset >= payload.size) return null
                offset += 1
            }

            // Read OBU payload size
            val obuSize: Int
            if (hasSizeField != 0) {
                val (size, count) = readLEB128(payload, offset) ?: return null
                obuSize = size
                offset += count
            } else {
                // No size field: this OBU extends to the end of the payload
                obuSize = payload.size - offset
            }

            if (offset + obuSize > payload.size) return null

            if (obuType == 1) {  // OBU_SEQUENCE_HEADER
                return payload.copyOfRange(headerStart, offset + obuSize)
            }

            offset += obuSize
        }

        return null
    }

    /**
     * Build a minimal av1C (AV1 Codec Configuration Record) from a raw Sequence Header OBU.
     *
     * Layout (ISO 14496-12 annex T):
     *   Byte 0: 0x81  (marker=1 | version=1)
     *   Byte 1: seqProfile << 5
     *   Byte 2: 0x0C  (subsampling_x=1, subsampling_y=1 — YUV 4:2:0 default)
     *   Byte 3: 0x00  (initial_presentation_delay_present=0)
     *   Bytes 4+: sequence header OBU bytes
     */
    fun buildMinimalAv1c(sequenceHeader: ByteArray): ByteArray {
        val seqProfile = extractSeqProfile(sequenceHeader)
        val header = byteArrayOf(
            0x81.toByte(),
            (seqProfile.toInt() shl 5).toByte(),
            0x0C,
            0x00,
        )
        return header + sequenceHeader
    }

    /** Extract seq_profile (3 bits) from the body of a Sequence Header OBU. */
    private fun extractSeqProfile(obu: ByteArray): Byte {
        if (obu.isEmpty()) return 0
        val header = obu[0].toInt() and 0xFF
        val extensionFlag = (header shr 2) and 0x1
        val hasSizeField = (header shr 1) and 0x1
        var pos = 1 + if (extensionFlag != 0) 1 else 0
        if (hasSizeField != 0) {
            // Skip LEB128 size bytes
            while (pos < obu.size && (obu[pos].toInt() and 0x80) != 0) pos++
            if (pos < obu.size) pos++
        }
        if (pos >= obu.size) return 0
        return ((obu[pos].toInt() and 0xFF) shr 5).toByte()
    }

    /** Read a LEB128-encoded unsigned integer. Returns (value, bytesRead) or null if malformed. */
    private fun readLEB128(data: ByteArray, offset: Int): Pair<Int, Int>? {
        var result = 0
        var shift = 0
        var pos = offset

        while (pos < data.size) {
            val byte = data[pos].toInt() and 0xFF
            pos++
            result = result or ((byte and 0x7F) shl shift)
            if ((byte and 0x80) == 0) {
                return Pair(result, pos - offset)
            }
            shift += 7
            if (shift >= 35) return null  // guard against absurdly large values
        }

        return null  // truncated
    }
}
