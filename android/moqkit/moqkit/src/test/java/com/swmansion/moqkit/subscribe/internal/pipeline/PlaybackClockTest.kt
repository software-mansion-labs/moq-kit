package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.RetargetDecision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackClockTest {
    @Test
    fun configuredAudioMasterIsNotReplacedWhenItsDriverDetaches() {
        val time = FakeTimeSource(0)
        val clock = PlaybackClock(
            ClockPolicy(),
            time,
            masterDriverKind = DriverKind.AUDIO,
        )
        val audio = MutableClockDriver(200)
        clock.attachAudioDriver(audio)

        assertEquals(DriverKind.AUDIO, clock.masterDriverKind)
        assertEquals(200L, clock.nowMediaUs())

        clock.detachAudioDriver()
        time.advance(500_000)

        assertEquals(DriverKind.AUDIO, clock.masterDriverKind)
        assertNull(clock.nowMediaUs())
    }

    @Test
    fun attachedAudioDriverProvidesConfiguredMasterPosition() {
        val time = FakeTimeSource(0)
        val clock = PlaybackClock(
            ClockPolicy(),
            time,
            masterDriverKind = DriverKind.AUDIO,
        )
        val audio = MutableClockDriver(null)
        clock.startVideoAt(100)
        clock.attachAudioDriver(audio)

        assertEquals(DriverKind.AUDIO, clock.masterDriverKind)
        assertNull(clock.nowMediaUs())

        audio.position = 200
        assertEquals(200L, clock.nowMediaUs())
    }

    @Test
    fun videoClockStartsPausesResumesAndResets() {
        val time = FakeTimeSource(1_000_000)
        val clock = PlaybackClock(ClockPolicy(), time)

        clock.startVideoAt(10_000)
        time.advance(500_000)
        assertEquals(10_500L, clock.nowMediaUs())

        clock.pauseVideo()
        time.advance(1_000_000)
        assertEquals(10_500L, clock.nowMediaUs())

        clock.resumeVideo()
        time.advance(250_000)
        assertEquals(10_750L, clock.nowMediaUs())

        clock.resetVideo()
        assertNull(clock.nowMediaUs())
    }

    @Test
    fun retargetAppliesNoOpNudgeAndJumpFromNamedPolicyBounds() {
        val driver = AdjustableDriver(900)
        val clock = PlaybackClock(
            ClockPolicy(
                retargetToleranceUs = 20,
                jumpThresholdUs = 200,
                minRate = 0.9,
                maxRate = 1.1,
            ),
            FakeTimeSource(0),
            videoDriver = driver,
        )
        clock.onLiveEdge(1_000)

        assertEquals(RetargetDecision.NoOp, clock.retarget(targetLatencyUs = 90))
        assertEquals(1.0, driver.currentRate, 0.0)

        val nudge = clock.retarget(targetLatencyUs = 50)
        assertTrue(nudge is RetargetDecision.Nudge)
        assertTrue(driver.currentRate > 1.0)

        driver.position = 500
        assertEquals(RetargetDecision.Jump(900), clock.retarget(targetLatencyUs = 100))
        assertEquals(900L, driver.position)
        assertEquals(1.0, driver.currentRate, 0.0)
    }

    @Test
    fun retargetSlowsVideoClockWhenPlaybackIsAheadOfTarget() {
        val driver = AdjustableDriver(950)
        val clock = PlaybackClock(
            ClockPolicy(
                retargetToleranceUs = 20,
                jumpThresholdUs = 100,
                minRate = 0.9,
                maxRate = 1.1,
            ),
            FakeTimeSource(0),
            videoDriver = driver,
        )
        clock.onLiveEdge(1_000)

        val decision = clock.retarget(targetLatencyUs = 100)

        assertTrue(decision is RetargetDecision.Nudge)
        assertTrue(driver.currentRate < 1.0)
    }

    @Test
    fun audioMasterSuppressesVideoRetargeting() {
        val video = AdjustableDriver(500)
        val clock = PlaybackClock(
            ClockPolicy(),
            FakeTimeSource(0),
            masterDriverKind = DriverKind.AUDIO,
            videoDriver = video,
        )
        clock.attachAudioDriver(MutableClockDriver(700))
        clock.onLiveEdge(1_000)

        assertEquals(RetargetDecision.NoOp, clock.retarget(targetLatencyUs = 100))
        assertEquals(500L, video.position)
    }

    private class MutableClockDriver(var position: Long?) : ClockDriver {
        override fun positionUs(): Long? = position
    }

    private class AdjustableDriver(
        var position: Long?,
    ) : AdjustableClockDriver {
        var currentRate: Double = 0.0

        override fun positionUs(): Long? = position

        override fun setRate(rate: Double) {
            currentRate = rate
        }

        override fun setPositionAndRate(positionUs: Long, rate: Double) {
            position = positionUs
            currentRate = rate
        }

        override fun reset() {
            position = null
            currentRate = 0.0
        }
    }
}
