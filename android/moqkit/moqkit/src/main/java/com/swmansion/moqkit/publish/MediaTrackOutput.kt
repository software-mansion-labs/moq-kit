package com.swmansion.moqkit.publish

import dev.moq.BroadcastProducer
import dev.moq.Frame
import dev.moq.Init
import dev.moq.MediaProducer

/** One encoder generation; late callbacks cannot recreate a finished media track. */
internal class MediaTrackOutput(
    private val broadcast: BroadcastProducer,
    private val format: String,
    private val onActive: () -> Unit,
    private val onError: (Exception) -> Unit,
) {
    private var closed = false
    private var producer: MediaProducer? = null

    @Synchronized
    fun write(data: ByteArray, initData: ByteArray?, timestampUs: Long) {
        if (closed) return
        try {
            if (producer == null) {
                if (initData == null) return
                producer = broadcast.publishMedia(Init(format = format, data = initData, video = null))
                onActive()
            }
            producer?.writeFrame(Frame(payload = data, timestampUs = timestampUs.toULong()))
        } catch (e: Exception) {
            fail(e)
        }
    }

    @Synchronized
    fun fail(error: Exception) {
        if (closed) return
        finish()
        onError(error)
    }

    @Synchronized
    fun finish() {
        closed = true
        try { producer?.finish() } catch (_: Exception) {}
        try { producer?.close() } catch (_: Exception) {}
        producer = null
    }
}
