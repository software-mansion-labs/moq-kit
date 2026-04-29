package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.codec.AV1Utils

internal object Av1CodecConfig {
    fun csdFromTemporalUnit(payload: ByteArray): Map<String, ByteArray>? {
        val sequenceHeader = AV1Utils.extractSequenceHeader(payload) ?: return null
        return mapOf("csd-0" to AV1Utils.buildMinimalAv1c(sequenceHeader))
    }
}
