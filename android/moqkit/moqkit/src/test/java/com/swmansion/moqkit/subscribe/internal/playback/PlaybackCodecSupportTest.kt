package com.swmansion.moqkit.subscribe.internal.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.moq.Container
import uniffi.moq.MoqAudio
import uniffi.moq.MoqDimensions
import uniffi.moq.MoqVideo

class PlaybackCodecSupportTest {
    @Test
    fun videoMimeMapsSupportedCodecFamilies() {
        assertEquals(CodecMime.VIDEO_AVC, PlaybackCodecSupport.videoMime("avc1"))
        assertEquals(CodecMime.VIDEO_AVC, PlaybackCodecSupport.videoMime("avc3.64001f"))
        assertEquals(CodecMime.VIDEO_HEVC, PlaybackCodecSupport.videoMime("hev1"))
        assertEquals(CodecMime.VIDEO_HEVC, PlaybackCodecSupport.videoMime("hvc1.1.6.L93.B0"))
        assertEquals(CodecMime.VIDEO_AV1, PlaybackCodecSupport.videoMime("av01.0.04M.08"))
        assertEquals(CodecMime.VIDEO_AV1, PlaybackCodecSupport.videoMime("AV01"))
    }

    @Test
    fun audioMimeMapsSupportedCodecFamilies() {
        assertEquals(CodecMime.AUDIO_AAC, PlaybackCodecSupport.audioMime("mp4a.40.2"))
        assertEquals(CodecMime.AUDIO_AAC, PlaybackCodecSupport.audioMime("aac"))
        assertEquals(CodecMime.AUDIO_OPUS, PlaybackCodecSupport.audioMime("opus"))
        assertEquals(CodecMime.AUDIO_OPUS, PlaybackCodecSupport.audioMime("OPUS"))
    }

    @Test
    fun unsupportedCodecStringsAreRejectedWithoutDecoderQuery() {
        val videoResult = PlaybackCodecSupport.video(videoConfig("vp09"))
        val audioResult = PlaybackCodecSupport.audio(audioConfig("flac"))

        assertFalse(videoResult.isSupported)
        assertTrue(videoResult.reason!!.contains("Unsupported video codec"))
        assertFalse(audioResult.isSupported)
        assertTrue(audioResult.reason!!.contains("Unsupported audio codec"))
        assertNull(PlaybackCodecSupport.videoMime("vp09"))
        assertNull(PlaybackCodecSupport.audioMime("flac"))
    }

    private fun videoConfig(codec: String): MoqVideo = MoqVideo(
        codec = codec,
        description = null,
        coded = MoqDimensions(1920u, 1080u),
        displayRatio = null,
        bitrate = null,
        framerate = null,
        container = Container.Legacy,
    )

    private fun audioConfig(codec: String): MoqAudio = MoqAudio(
        codec = codec,
        description = null,
        sampleRate = 48_000u,
        channelCount = 2u,
        bitrate = null,
        container = Container.Legacy,
    )
}
