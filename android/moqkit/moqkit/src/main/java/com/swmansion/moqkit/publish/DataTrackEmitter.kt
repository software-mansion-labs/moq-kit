package com.swmansion.moqkit.publish

import uniffi.moq.MoqTrackProducer

/**
 * Push-based source for publishing raw binary frames on a data track.
 */
class DataTrackEmitter {
    @Volatile private var producer: MoqTrackProducer? = null
    @Volatile private var stopped = false

    internal fun attach(producer: MoqTrackProducer) {
        stopped = false
        this.producer = producer
    }

    internal fun detach() {
        stopped = true
        producer = null
    }

    fun send(data: ByteArray) {
        if (stopped) return
        producer?.writeFrame(data)
    }
}
