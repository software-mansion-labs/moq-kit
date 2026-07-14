package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionEffect
import com.swmansion.moqkit.subscribe.internal.pipeline.AdmissionRejectReason
import com.swmansion.moqkit.subscribe.internal.pipeline.FakeTimeSource
import com.swmansion.moqkit.subscribe.internal.pipeline.IngestEvent
import com.swmansion.moqkit.subscribe.internal.pipeline.TimedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.TimelinePolicy
import com.swmansion.moqkit.subscribe.internal.pipeline.TrackTimeline
import com.swmansion.moqkit.subscribe.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration

class VideoRendererTrackTest {
    private val timeline = TrackTimeline(TimelinePolicy(targetLatencyUs = 1_000L), FakeTimeSource(0L))

    @Test
    fun buffersToTargetThenDrainsInDecodeOrder() {
        val track = track(targetBuffering = Duration.ofMillis(1))

        track.insert(byteArrayOf(1), timestampUs = 1_000L, keyframe = true)
        assertEquals(VideoBufferState.BUFFERING, track.state)
        track.insert(byteArrayOf(2), timestampUs = 2_000L, keyframe = false)

        assertEquals(VideoBufferState.PLAYING, track.state)
        assertEquals(1_000L, track.dequeue().first?.timestampUs)
        assertEquals(2_000L, track.dequeue().first?.timestampUs)
    }

    @Test
    fun resetFlushesFramesAndRearmsKeyframeGate() {
        val track = track(targetBuffering = Duration.ZERO)
        track.insert(byteArrayOf(1), timestampUs = 1_000L, keyframe = true)
        track.insert(byteArrayOf(2), timestampUs = 1_001L, keyframe = false)

        assertEquals(2, track.flush())
        val result = track.insert(byteArrayOf(3), timestampUs = 2_000L, keyframe = false)

        val rejection = (result as VideoTrackInsertResult.Buffered)
            .effects
            .single() as AdmissionEffect.Rejected
        assertEquals(AdmissionRejectReason.WAITING_FOR_KEYFRAME, rejection.reason)
        assertNull(track.peekFront())
    }

    @Test
    fun bufferReportsWaitingForKeyframeBeforePayloadProcessing() {
        val track = track(
            targetBuffering = Duration.ZERO,
            processor = FakeVideoPayloadProcessor(isReady = false),
        )

        val result = track.insert(byteArrayOf(3), timestampUs = 2_000L, keyframe = false)

        val rejection = (result as VideoTrackInsertResult.Buffered)
            .effects
            .single() as AdmissionEffect.Rejected
        assertEquals(AdmissionRejectReason.WAITING_FOR_KEYFRAME, rejection.reason)
    }

    @Test
    fun pendingTrackOnlyNotifiesWhenAKeyframeCanAnchorTheSwitch() {
        var notifications = 0
        val track = track(targetBuffering = Duration.ofSeconds(1))
        track.setBufferState(VideoBufferState.PENDING)
        track.setOnDataAvailable { notifications++ }

        track.insert(byteArrayOf(1), timestampUs = 1_000L, keyframe = false)
        track.insert(byteArrayOf(2), timestampUs = 2_000L, keyframe = true)

        assertEquals(1, notifications)
        assertTrue(track.firstKeyframePts != null)
    }

    @Test
    fun reportsFramesDiscardedWhilePreparingARenditionSwitch() {
        val track = track(targetBuffering = Duration.ZERO)
        track.setBufferState(VideoBufferState.PENDING)
        track.insert(byteArrayOf(0), timestampUs = 500L, keyframe = true)
        track.insert(byteArrayOf(1), timestampUs = 1_000L, keyframe = false)
        track.insert(byteArrayOf(2), timestampUs = 2_000L, keyframe = false)
        track.insert(byteArrayOf(3), timestampUs = 3_000L, keyframe = true)
        assertTrue(track.discardFront())

        assertEquals(2, track.discardNonKeyframesBeforePts(3_000L))
        assertEquals(3_000L, track.peekFront()?.first)
    }

    @Test
    fun loweringTargetLatencyCanReleaseAnAlreadyBufferedTrack() {
        val track = track(targetBuffering = Duration.ofMillis(2))
        track.insert(byteArrayOf(1), timestampUs = 1_000L, keyframe = true)
        track.insert(byteArrayOf(2), timestampUs = 2_000L, keyframe = false)
        assertEquals(VideoBufferState.BUFFERING, track.state)

        assertTrue(track.updateTargetBuffering(Duration.ofMillis(1)))
        assertEquals(VideoBufferState.PLAYING, track.state)
    }

    @Test
    fun playbackTargetComesFromTimelineLiveEdgeMinusTargetLatency() {
        val time = FakeTimeSource(0L)
        val timeline = TrackTimeline(TimelinePolicy(targetLatencyUs = 1_000L), time)
        val track = track(targetBuffering = Duration.ofMillis(1), timeline = timeline)
        timeline.onIngest(
            IngestEvent.Frame(
                TimedFrame(MediaFrame(ByteArray(1), 10_000L, true), epoch = 1L),
                arrivalNanos = time.nanoTime(),
            ),
        )
        time.advance(500_000L)

        assertEquals(9_500L, track.targetPlaybackPTS())
    }

    private fun track(
        targetBuffering: Duration,
        processor: VideoPayloadProcessor = FakeVideoPayloadProcessor(),
        timeline: TrackTimeline = this.timeline,
    ) = VideoRendererTrack(
        trackName = "video",
        trackEpoch = 1L,
        targetBuffering = targetBuffering,
        timeline = timeline,
        processor = processor,
    )
}

private class FakeVideoPayloadProcessor(
    override val isReady: Boolean = true,
) : VideoPayloadProcessor {
    override fun processPayload(payload: ByteArray, keyframe: Boolean): ByteArray? =
        payload.takeIf { isReady || keyframe }
    override fun getFormat(): MediaFormat? = null
}
