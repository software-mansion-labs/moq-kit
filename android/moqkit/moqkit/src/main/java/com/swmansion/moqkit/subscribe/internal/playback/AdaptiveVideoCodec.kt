package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat

/** Codec compatibility and configuration-data handling for adaptive rendition switches. */
internal object AdaptiveVideoCodec {
    fun requireCompatible(active: MediaFormat?, pending: MediaFormat?) {
        requireCompatibleMime(
            active?.getString(MediaFormat.KEY_MIME),
            pending?.getString(MediaFormat.KEY_MIME),
        )
    }

    fun requireCompatibleMime(active: String?, pending: String?) {
        if (active != null && pending != null && active != pending) {
            error("Cannot switch codecs during adaptive swap: $active -> $pending")
        }
    }

    fun codecData(format: MediaFormat?): ByteArray? {
        val first = format?.getByteBuffer("csd-0")?.copyBytes() ?: return null
        val second = format.getByteBuffer("csd-1")?.copyBytes() ?: return first
        return first + second
    }

    private fun java.nio.ByteBuffer.copyBytes(): ByteArray {
        rewind()
        return ByteArray(remaining()).also(::get)
    }
}
