package com.swmansion.moqkit.publish

/**
 * Push-based source for publishing raw binary frames on a data track.
 *
 * NOTE: Full support requires Android bindings rebuild to expose `MoqTrackProducer`.
 * Run `mise run build-android` to regenerate bindings from the current Rust source.
 * After rebuild, update [MoQPublisher.startDataTrack] to wire a real `MoqTrackProducer`.
 */
class DataTrackEmitter {
    @Volatile internal var frameWriter: ((ByteArray) -> Unit)? = null
    @Volatile private var stopped = false

    internal fun attachWriter(writer: (ByteArray) -> Unit) {
        stopped = false
        frameWriter = writer
    }

    internal fun detach() {
        stopped = true
        frameWriter = null
    }

    fun send(data: ByteArray) {
        if (stopped) return
        try { frameWriter?.invoke(data) } catch (_: Exception) {}
    }
}
