package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import uniffi.moq.MoqAudio
import uniffi.moq.MoqVideo
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.util.Log



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
            MediaFormat.MIMETYPE_VIDEO_AV1 -> format.setByteBuffer("csd-0", ByteBuffer.wrap(desc))
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
        Log.d("MediaFactory", "mime $mime")
        when (mime) {
            MediaFormat.MIMETYPE_AUDIO_AAC -> {
                val csd = desc?.let { ByteBuffer.wrap(it) }
                    ?: generateAacCsd(config.sampleRate.toInt(), config.channelCount.toInt())
                format.setByteBuffer("csd-0", csd)
            }
            MediaFormat.MIMETYPE_AUDIO_OPUS -> {
                // csd-0: Opus identification header
                // csd-1: codec delay (pre-skip) in nanoseconds, little-endian int64
                // csd-2: seek pre-roll in nanoseconds, little-endian int64
                val header = desc ?: generateOpusHeader(config.sampleRate.toInt(), config.channelCount.toInt())
                val preSkipSamples = if (header.size >= 12) {
                    ((header[11].toInt() and 0xFF) shl 8) or (header[10].toInt() and 0xFF)
                } else {
                    312 // default pre-skip at 48 kHz
                }
                val codecDelayNs = preSkipSamples * 1_000_000_000L / 48000
                val seekPreRollNs = 80_000_000L // 80 ms
                format.setByteBuffer("csd-0", ByteBuffer.wrap(header))
                format.setByteBuffer("csd-1", longToLeBuffer(codecDelayNs))
                format.setByteBuffer("csd-2", longToLeBuffer(seekPreRollNs))
            }
            else -> return null
        }
        return format
    }

    private fun longToLeBuffer(value: Long): ByteBuffer =
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).also { it.flip() }

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

    // Generate a minimal Opus identification header (RFC 7845 §5.1) for mono/stereo streams.
    // Channel mapping family 0 supports 1–2 channels without an explicit mapping table.
    private fun generateOpusHeader(sampleRate: Int, channelCount: Int): ByteArray {
        val preSkip: Short = 312 // standard pre-skip at 48 kHz
        return ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            .put("OpusHead".toByteArray(Charsets.US_ASCII)) // magic (8 bytes)
            .put(1.toByte())                                 // version
            .put(channelCount.toByte())                      // channel count
            .putShort(preSkip)                               // pre-skip (LE uint16)
            .putInt(sampleRate)                              // input sample rate (LE uint32)
            .putShort(0)                                     // output gain (LE int16)
            .put(0.toByte())                                 // channel mapping family 0
            .array()
    }

    fun videoMime(codec: String): String? = when {
        codec.startsWith("avc") -> MediaFormat.MIMETYPE_VIDEO_AVC
        codec.startsWith("hev") || codec.startsWith("hvc") -> MediaFormat.MIMETYPE_VIDEO_HEVC
        codec.startsWith("av0") -> MediaFormat.MIMETYPE_VIDEO_AV1
        else -> null
    }

    private fun audioMime(codec: String): String? = when {
        codec.startsWith("mp4a") || codec.startsWith("aac") -> MediaFormat.MIMETYPE_AUDIO_AAC
        codec.startsWith("opus") -> MediaFormat.MIMETYPE_AUDIO_OPUS
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

    private fun annexBWrap(src: ByteArray, offset: Int, length: Int): ByteArray {
        val buf = ByteArray(4 + length)
        buf[3] = 1
        System.arraycopy(src, offset, buf, 4, length)
        return buf
    }
}
