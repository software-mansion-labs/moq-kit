package com.swmansion.moqkit.subscribe.internal.playback

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal val ANNEX_B_START_CODE = byteArrayOf(0, 0, 0, 1)

internal fun annexBWrap(src: ByteArray, offset: Int, length: Int): ByteArray {
    val out = ByteArray(ANNEX_B_START_CODE.size + length)
    System.arraycopy(ANNEX_B_START_CODE, 0, out, 0, ANNEX_B_START_CODE.size)
    System.arraycopy(src, offset, out, ANNEX_B_START_CODE.size, length)
    return out
}

internal fun readUInt16(src: ByteArray, offset: Int): Int =
    ((src[offset].toInt() and 0xFF) shl 8) or (src[offset + 1].toInt() and 0xFF)

internal fun Long.toLittleEndianBytes(): ByteArray =
    ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(this).array()
