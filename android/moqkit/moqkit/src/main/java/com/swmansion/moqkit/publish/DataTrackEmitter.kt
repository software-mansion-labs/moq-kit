package com.swmansion.moqkit.publish

import android.os.SystemClock
import dev.moq.Frame
import dev.moq.TrackProducer

/**
 * Sends raw binary payloads on a data track.
 *
 * Create an emitter, pass it to [Publisher.addDataTrack], publish and start the
 * [Publisher], then call [send] whenever the app has a payload to deliver.
 */
class DataTrackEmitter {
    @Volatile private var producer: TrackProducer? = null
    @Volatile private var clock: Clock? = null
    @Volatile private var stopped = false

    internal fun attach(producer: TrackProducer, clock: Clock) {
        stopped = false
        this.clock = clock
        this.producer = producer
    }

    internal fun detach() {
        stopped = true
        producer = null
        clock = null
    }

    /**
     * Sends one binary payload.
     *
     * If the publisher has not started yet, or if the data track has already stopped, this
     * call is ignored.
     */
    fun send(data: ByteArray) {
        if (stopped) return
        val producer = producer ?: return
        // Stamp against the publisher clock so data frames share the epoch of the
        // broadcast's media tracks.
        val nowUs = SystemClock.elapsedRealtimeNanos() / 1_000
        val timestampUs = clock?.timestampUs(nowUs) ?: 0L
        producer.writeFrame(Frame(payload = data, timestampUs = timestampUs.toULong()))
    }
}
