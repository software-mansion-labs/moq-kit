package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoRendererProgressTest {
    @Test
    fun renditionSwitchProgressDoesNotMoveBackwardForBFrames() {
        var progressUs = 0L

        progressUs = advanceRenditionSwitchProgressUs(progressUs, submittedPtsUs = 0L)
        progressUs = advanceRenditionSwitchProgressUs(progressUs, submittedPtsUs = 66L)
        progressUs = advanceRenditionSwitchProgressUs(progressUs, submittedPtsUs = 33L)

        assertEquals(66L, progressUs)
        assertTrue(progressUs >= 50L)
    }
}
