@file:OptIn(UnstableApi::class)

package com.swmansion.moqkit

import android.media.MediaFormat
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import uniffi.moq.MoqAudio
import uniffi.moq.MoqVideo
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

internal object MediaFactory {
    fun makeVideoFormat(config: MoqVideo): MediaFormat? {
        val mime = videoMime(config.codec) ?: return null
        val desc = config.description ?: return null

        val width = config.coded?.width?.toInt() ?: 1920
        val height = config.coded?.height?.toInt() ?: 1080
        val format = MediaFormat.createVideoFormat(mime, width, height)

        when (mime) {
            MediaFormat.MIMETYPE_VIDEO_AVC -> parseAvcc(desc, format)
            MediaFormat.MIMETYPE_VIDEO_HEVC -> parseHvcc(desc, format)
        }
        return format
    }

    fun makeAudioFormat(config: MoqAudio): MediaFormat? {
        val mime = audioMime(config.codec) ?: return null
        val desc = config.description

        val format = MediaFormat.createAudioFormat(
            mime,
            config.sampleRate.toInt(),
            config.channelCount.toInt(),
        )
        if (desc != null) {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(desc))
        } else if (mime == MediaFormat.MIMETYPE_AUDIO_AAC) {
            format.setByteBuffer("csd-0", this.generateAacCsd(config.sampleRate.toInt(), config.channelCount.toInt()))
        } else {
            return null
        }
        return format
    }

    private fun generateAacCsd(sampleRate: Int, channelCount: Int): ByteBuffer {
        val sampleRateIndex = when (sampleRate) {
            96000 -> 0; 88200 -> 1; 64000 -> 2; 48000 -> 3
            44100 -> 4; 32000 -> 5; 24000 -> 6; 22050 -> 7
            16000 -> 8; 12000 -> 9; 11025 -> 10; 8000 -> 11
            else -> 4 // Default to 44100 if unknown
        }

        // AAC-LC = 2
        val csd = ByteArray(2)
        csd[0] = ((2 shl 3) or (sampleRateIndex shr 1)).toByte()
        csd[1] = (((sampleRateIndex and 0x01) shl 7) or (channelCount shl 3)).toByte()

        return ByteBuffer.wrap(csd)
    }

    fun makeVideoFormatMedia3(config: MoqVideo): Format? {
        val mime = videoMimeMedia3(config.codec) ?: return null
        val desc = config.description ?: return null

        val width = config.coded?.width?.toInt() ?: 1920
        val height = config.coded?.height?.toInt() ?: 1080
        val csd = when (mime) {
            MimeTypes.VIDEO_H264 -> buildAvccCsd(desc)
            MimeTypes.VIDEO_H265 -> buildHvccCsd(desc)
            else -> emptyList()
        }

        return Format.Builder()
            .setSampleMimeType(mime)
            .setWidth(width)
            .setHeight(height)
            .setInitializationData(csd)
            .build()
    }

    fun makeAudioFormatMedia3(config: MoqAudio): Format? {
        val mime = audioMimeMedia3(config.codec) ?: return null
        val desc: ByteArray = when (mime) {
            MimeTypes.AUDIO_AAC -> config.description
                ?: generateAacCsd(config.sampleRate.toInt(), config.channelCount.toInt()).let { buf ->
                    ByteArray(buf.capacity()).also { buf.get(it) }
                }
            else -> config.description ?: return null
        }


        return Format.Builder()
            .setSampleMimeType(mime)
            .setSampleRate(config.sampleRate.toInt())
            .setChannelCount(config.channelCount.toInt())
            .setAverageBitrate(128000)
            .setInitializationData(listOf(desc))
            .build()
    }

    fun videoMime(codec: String): String? = when {
        codec.startsWith("avc") -> MediaFormat.MIMETYPE_VIDEO_AVC
        codec.startsWith("hev") || codec.startsWith("hvc") -> MediaFormat.MIMETYPE_VIDEO_HEVC
        else -> null
    }

    private fun audioMime(codec: String): String? = when {
        codec.startsWith("mp4a") || codec.startsWith("aac") -> MediaFormat.MIMETYPE_AUDIO_AAC
        codec.startsWith("opus") -> MediaFormat.MIMETYPE_AUDIO_OPUS
        else -> null
    }

    private fun videoMimeMedia3(codec: String): String? = when {
        codec.startsWith("avc") -> MimeTypes.VIDEO_H264
        codec.startsWith("hev") || codec.startsWith("hvc") -> MimeTypes.VIDEO_H265
        else -> null
    }

    private fun audioMimeMedia3(codec: String): String? = when {
        codec.startsWith("mp4a") || codec.startsWith("aac") -> MimeTypes.AUDIO_AAC
        codec.startsWith("opus") -> MimeTypes.AUDIO_OPUS
        else -> null
    }

    // Parse AVCDecoderConfigurationRecord to extract SPS/PPS and set csd-0/csd-1
    private fun parseAvcc(desc: ByteArray, format: MediaFormat) {
        // [0]: version, [1]: profile, [2]: compat, [3]: level, [4]: lengthSizeMinusOne
        // [5]: numSPS (lower 5 bits), [6-7]: spsLength, [8..]: sps bytes
        // [8+spsLen]: numPPS, [9+spsLen..10+spsLen]: ppsLength, [11+spsLen..]: pps bytes
        var pos = 5
        if (pos >= desc.size) return

        val numSps = desc[pos++].toInt() and 0x1F
        if (numSps > 0 && pos + 2 <= desc.size) {
            val spsLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            if (pos + spsLen <= desc.size) {
                format.setByteBuffer("csd-0", ByteBuffer.wrap(annexBWrap(desc, pos, spsLen)))
                pos += spsLen
            }
        }

        if (pos >= desc.size) return
        val numPps = desc[pos++].toInt() and 0xFF
        if (numPps > 0 && pos + 2 <= desc.size) {
            val ppsLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            if (pos + ppsLen <= desc.size) {
                format.setByteBuffer("csd-1", ByteBuffer.wrap(annexBWrap(desc, pos, ppsLen)))
            }
        }
    }

    // Parse HEVCDecoderConfigurationRecord, combine VPS/SPS/PPS into csd-0
    private fun parseHvcc(desc: ByteArray, format: MediaFormat) {
        // Header is 22 bytes, then numArrays
        var pos = 22
        if (pos >= desc.size) return

        val numArrays = desc[pos++].toInt() and 0xFF
        val out = ByteArrayOutputStream()

        repeat(numArrays) {
            if (pos + 3 > desc.size) return
            pos++ // NAL type byte
            val numNalus = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            repeat(numNalus) {
                if (pos + 2 > desc.size) return
                val naluLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
                pos += 2
                if (pos + naluLen > desc.size) return
                out.write(byteArrayOf(0, 0, 0, 1))
                out.write(desc, pos, naluLen)
                pos += naluLen
            }
        }

        val combined = out.toByteArray()
        if (combined.isNotEmpty()) {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(combined))
        }
    }

    // Build CSD byte arrays from AVCDecoderConfigurationRecord for Media3 Format
    private fun buildAvccCsd(desc: ByteArray): List<ByteArray> {
        var pos = 5
        if (pos >= desc.size) return emptyList()
        val result = mutableListOf<ByteArray>()

        val numSps = desc[pos++].toInt() and 0x1F
        if (numSps > 0 && pos + 2 <= desc.size) {
            val spsLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            if (pos + spsLen <= desc.size) {
                result.add(annexBWrap(desc, pos, spsLen))
                pos += spsLen
            }
        }

        if (pos >= desc.size) return result
        val numPps = desc[pos++].toInt() and 0xFF
        if (numPps > 0 && pos + 2 <= desc.size) {
            val ppsLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            if (pos + ppsLen <= desc.size) {
                result.add(annexBWrap(desc, pos, ppsLen))
            }
        }

        return result
    }

    // Build combined CSD byte array from HEVCDecoderConfigurationRecord for Media3 Format
    private fun buildHvccCsd(desc: ByteArray): List<ByteArray> {
        var pos = 22
        if (pos >= desc.size) return emptyList()

        val numArrays = desc[pos++].toInt() and 0xFF
        val out = ByteArrayOutputStream()

        for (i in 0 until numArrays) {
            if (pos + 3 > desc.size) break
            pos++ // NAL type byte
            val numNalus = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
            pos += 2
            for (j in 0 until numNalus) {
                if (pos + 2 > desc.size) break
                val naluLen = ((desc[pos].toInt() and 0xFF) shl 8) or (desc[pos + 1].toInt() and 0xFF)
                pos += 2
                if (pos + naluLen > desc.size) break
                out.write(byteArrayOf(0, 0, 0, 1))
                out.write(desc, pos, naluLen)
                pos += naluLen
            }
        }

        val combined = out.toByteArray()
        return if (combined.isNotEmpty()) listOf(combined) else emptyList()
    }

    private fun annexBWrap(src: ByteArray, offset: Int, length: Int): ByteArray {
        val buf = ByteArray(4 + length)
        buf[3] = 1
        System.arraycopy(src, offset, buf, 4, length)
        return buf
    }
}
