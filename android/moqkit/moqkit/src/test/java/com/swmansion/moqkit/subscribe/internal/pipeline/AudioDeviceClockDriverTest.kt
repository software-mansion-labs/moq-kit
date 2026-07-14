package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AudioDeviceClockDriverTest {
    @Test
    fun playbackHeadMapsWrittenFramesToMediaTime() {
        var playbackHead = 0L
        val driver = AudioDeviceClockDriver(sampleRate = 1_000) { playbackHead }

        assertNull(driver.positionUs())

        driver.onFramesWritten(mediaStartUs = 10_000, frameCount = 100)
        assertEquals(10_000L, driver.positionUs())

        playbackHead = 50
        assertEquals(60_000L, driver.positionUs())

        playbackHead = 100
        assertEquals(110_000L, driver.positionUs())
    }

    @Test
    fun firstWriteUsesDeviceFrameZeroWhenPlaybackHeadAlreadyAdvanced() {
        var playbackHead = 50L
        val driver = AudioDeviceClockDriver(sampleRate = 1_000) { playbackHead }

        driver.onFramesWritten(mediaStartUs = 10_000, frameCount = 100)

        assertEquals(60_000L, driver.positionUs())
    }

    @Test
    fun discontinuityCreatesANewTimestampSegmentWithoutMovingEarly() {
        var playbackHead = 0L
        val driver = AudioDeviceClockDriver(sampleRate = 1_000) { playbackHead }
        driver.onFramesWritten(mediaStartUs = 10_000, frameCount = 100)
        driver.onFramesWritten(mediaStartUs = 1_000_000, frameCount = 100)

        playbackHead = 50
        assertEquals(60_000L, driver.positionUs())

        playbackHead = 100
        assertEquals(1_000_000L, driver.positionUs())
    }

    @Test
    fun unsignedPlaybackHeadWrapRemainsMonotonic() {
        var playbackHead = 0xfffffff0L
        val driver = AudioDeviceClockDriver(sampleRate = 1_000) { playbackHead }
        driver.onFramesWritten(mediaStartUs = 5_000, frameCount = 64)
        val beforeWrapUs = driver.positionUs()!!

        playbackHead = 0x10L

        assertEquals(beforeWrapUs + 32_000L, driver.positionUs())
    }
}
