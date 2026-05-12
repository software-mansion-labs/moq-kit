package com.swmansion.moqkit.publish

import uniffi.moq.MoqTrackProducer

/**
 * Sends raw binary payloads on a data track.
 *
 * Create an emitter, pass it to [Publisher.addDataTrack], publish and start the
 * [Publisher], then call [send] whenever the app has a payload to deliver.
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

    /**
     * Sends one binary payload.
     *
     * If the publisher has not started yet, or if the data track has already stopped, this
     * call is ignored.
     */
    fun send(data: ByteArray) {
        if (stopped) return
        producer?.writeFrame(data)
    }
}
