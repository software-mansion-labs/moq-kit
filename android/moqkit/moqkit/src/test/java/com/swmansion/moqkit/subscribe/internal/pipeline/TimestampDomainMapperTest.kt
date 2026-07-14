package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.MediaFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimestampDomainMapperTest {
    private val time = FakeTimeSource(1_000_000L)
    private val audio = TrackTimeline(TimelinePolicy(), time)
    private val video = TrackTimeline(TimelinePolicy(), time)
    private val mapper = TimestampDomainMapper(
        audioTimeline = { audio },
        videoTimeline = { video },
    )

    @Test
    fun offsetRequiresBothTrackTimelines() {
        assertNull(mapper.videoOffsetUs(thresholdUs = 2_000L))
        assertNull(mapper.videoTimeUsOrNull(audioTimeUs = 10_000L, thresholdUs = 2_000L))

        audio.onIngest(frame(timestampUs = 10_000L, epoch = 1))

        assertNull(mapper.videoOffsetUs(thresholdUs = 2_000L))
    }

    @Test
    fun mapsBetweenAudioAndVideoTimestampDomains() {
        audio.onIngest(frame(timestampUs = 10_000L, epoch = 1))
        video.onIngest(frame(timestampUs = 4_000L, epoch = 1))

        assertEquals(6_000L, mapper.videoOffsetUs(thresholdUs = 2_000L))
        assertEquals(10_000L, mapper.audioTimeUs(videoTimeUs = 4_000L, thresholdUs = 2_000L))
        assertEquals(4_000L, mapper.videoTimeUs(audioTimeUs = 10_000L, thresholdUs = 2_000L))
    }

    @Test
    fun smallOffsetsDoNotRetargetTheTimestampDomain() {
        audio.onIngest(frame(timestampUs = 10_000L, epoch = 1))
        video.onIngest(frame(timestampUs = 9_000L, epoch = 1))

        assertNull(mapper.videoOffsetUs(thresholdUs = 2_000L))
        assertEquals(9_000L, mapper.audioTimeUs(videoTimeUs = 9_000L, thresholdUs = 2_000L))
        assertEquals(9_000L, mapper.videoTimeUsOrNull(audioTimeUs = 10_000L, thresholdUs = 0L))
    }

    private fun frame(timestampUs: Long, epoch: Long): IngestEvent.Frame =
        IngestEvent.Frame(
            frame = TimedFrame(
                mediaFrame = MediaFrame(ByteArray(1), timestampUs, keyframe = true),
                epoch = epoch,
            ),
            arrivalNanos = time.nanoTime(),
        )
}
