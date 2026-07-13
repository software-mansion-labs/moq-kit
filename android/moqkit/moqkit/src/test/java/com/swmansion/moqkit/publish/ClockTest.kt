package com.swmansion.moqkit.publish

import com.swmansion.moqkit.publish.source.AudioCaptureTimestampTracker
import org.junit.Assert.assertEquals
import org.junit.Test

class ClockTest {
    @Test
    fun explicitEpochKeepsTracksInOneTimestampDomain() {
        val clock = Clock()

        clock.start(epochUs = 1_000_000L)

        assertEquals(100_000L, clock.timestampUs(1_100_000L))
        assertEquals(125_000L, clock.timestampUs(1_125_000L))
    }

    @Test
    fun timestampBeforePublisherEpochClampsToZero() {
        val clock = Clock()

        clock.start(epochUs = 1_000_000L)

        assertEquals(0L, clock.timestampUs(999_000L))
    }
}

class AudioCaptureTimestampTrackerTest {
    @Test
    fun hardwareAnchorMapsTheFirstReadFrameIntoMonotonicTime() {
        val tracker = AudioCaptureTimestampTracker(sampleRate = 48_000)

        assertEquals(
            1_000_000L,
            tracker.timestampUs(
                framesRead = 480,
                anchorFramePosition = 480L,
                anchorTimeNs = 1_010_000_000L,
            ),
        )
        assertEquals(
            1_010_000L,
            tracker.timestampUs(
                framesRead = 480,
                anchorFramePosition = 960L,
                anchorTimeNs = 1_020_000_000L,
            ),
        )
    }

    @Test
    fun unavailableHardwareTimestampFallsBackToReadStartTime() {
        val tracker = AudioCaptureTimestampTracker(
            sampleRate = 48_000,
            monotonicTimeNs = { 2_000_000_000L },
        )

        assertEquals(
            1_990_000L,
            tracker.timestampUs(
                framesRead = 480,
                anchorFramePosition = null,
                anchorTimeNs = null,
            ),
        )
    }
}
