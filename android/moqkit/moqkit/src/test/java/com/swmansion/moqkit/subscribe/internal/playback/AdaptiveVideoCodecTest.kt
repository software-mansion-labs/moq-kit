package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertThrows
import org.junit.Test

class AdaptiveVideoCodecTest {
    @Test
    fun matchingMimeTypesAreCompatible() {
        AdaptiveVideoCodec.requireCompatibleMime("video/avc", "video/avc")
    }

    @Test
    fun unknownMimeTypeDoesNotRejectDeferredFormat() {
        AdaptiveVideoCodec.requireCompatibleMime("video/avc", null)
    }

    @Test
    fun differentMimeTypesAreRejected() {
        assertThrows(IllegalStateException::class.java) {
            AdaptiveVideoCodec.requireCompatibleMime("video/avc", "video/hevc")
        }
    }
}
