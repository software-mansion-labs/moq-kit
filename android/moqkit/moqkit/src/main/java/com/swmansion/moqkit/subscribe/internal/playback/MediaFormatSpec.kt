package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import java.nio.ByteBuffer

internal data class VideoFormatSpec(
    val mime: String,
    val width: Int,
    val height: Int,
    val csdBuffers: Map<String, ByteArray> = emptyMap(),
) {
    fun toMediaFormat(): MediaFormat {
        val format = MediaFormat.createVideoFormat(mime, width, height)
        csdBuffers.forEach { (key, value) ->
            format.setByteBuffer(key, ByteBuffer.wrap(value))
        }
        return format
    }
}

internal data class AudioFormatSpec(
    val mime: String,
    val sampleRate: Int,
    val channelCount: Int,
    val csdBuffers: Map<String, ByteArray> = emptyMap(),
) {
    fun toMediaFormat(): MediaFormat {
        val format = MediaFormat.createAudioFormat(mime, sampleRate, channelCount)
        csdBuffers.forEach { (key, value) ->
            format.setByteBuffer(key, ByteBuffer.wrap(value))
        }
        return format
    }
}

internal object CodecMime {
    const val VIDEO_AVC = "video/avc"
    const val VIDEO_HEVC = "video/hevc"
    const val VIDEO_AV1 = "video/av01"
    const val AUDIO_AAC = "audio/mp4a-latm"
    const val AUDIO_OPUS = "audio/opus"
}
