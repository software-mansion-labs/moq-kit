package com.swmansion.moqkit

import android.media.MediaFormat
import android.util.Log
import uniffi.moq.MoqVideo
import java.nio.ByteBuffer

private const val TAG = "VideoFrameProcessor"

/**
 * Selects the right payload transform and CSD extraction strategy based on the video config.
 *
 * - **Has description** (avc1/hev1/hvc1): payloads are AVCC/HVCC length-prefixed → convert to
 *   Annex B via [avccToAnnexB]; CSD parsed from the config record by [MediaFactory].
 * - **No description** (avc3/hev3): payloads are already Annex B → passthrough; CSD extracted
 *   in-band from the first keyframe containing parameter sets.
 *
 * Consumers call [processPayload] and get back ready-to-decode Annex B bytes.
 */
internal class VideoFrameProcessor(private val config: MoqVideo) {

    private val transform: (ByteArray) -> ByteArray
    private var format: MediaFormat? = null

    /** True once a MediaFormat with CSD is available and the decoder can be configured. */
    val isReady: Boolean get() = format != null

    init {
        transform = if (config.description != null) { payload -> payload.prefixLengthToAnnexB() }
                     else { payload -> payload }

        if (config.description != null) {
            format = MediaFactory.makeVideoFormat(config)
            if (format != null) {
                Log.d(TAG, "Format ready immediately: $format")
            } else {
                Log.w(TAG, "makeVideoFormat returned null for codec=${config.codec}")
            }
        } else {
            Log.d(TAG, "No description — deferring CSD extraction for codec=${config.codec}")
        }
    }

    /** Returns the MediaFormat once CSD is available, null otherwise. */
    fun getFormat(): MediaFormat? = format

    /**
     * Process a compressed video frame payload.
     *
     * @return Annex B bytes ready for MediaCodec, or null if the frame should be dropped
     *         (e.g., waiting for a keyframe with parameter sets).
     */
    fun processPayload(payload: ByteArray, keyframe: Boolean): ByteArray? {
        if (!isReady) {
            Log.i(TAG, "Video processor not ready")
            if (!keyframe) {
                Log.w(TAG, "Expected a keyframe when in not-ready state")
                return null
            }

            val mime = MediaFactory.videoMime(config.codec)
            if (mime == null) {
                Log.w(TAG, "Unsupported codec for in-band CSD: ${config.codec}")
                return null
            }

            val width = config.coded?.width?.toInt() ?: 1920
            val height = config.coded?.height?.toInt() ?: 1080
            val fmt = MediaFormat.createVideoFormat(mime, width, height)

            when (mime) {
                MediaFormat.MIMETYPE_VIDEO_AVC -> {
                    val params = AnnexBUtils.extractH264ParameterSets(payload)
                    if (params == null) {
                        Log.d(TAG, "Keyframe lacks H.264 SPS/PPS, dropping")
                        return null
                    }
                    Log.d(TAG, "Extracted in-band SPS (${params.sps.size}B) + PPS (${params.pps.size}B)")
                    fmt.setByteBuffer("csd-0", ByteBuffer.wrap(params.sps))
                    fmt.setByteBuffer("csd-1", ByteBuffer.wrap(params.pps))
                }
                MediaFormat.MIMETYPE_VIDEO_HEVC -> {
                    val csd = AnnexBUtils.extractH265ParameterSets(payload)
                    if (csd == null) {
                        Log.d(TAG, "Keyframe lacks H.265 VPS/SPS/PPS, dropping")
                        return null
                    }
                    Log.d(TAG, "Extracted in-band HEVC parameter sets (${csd.size}B)")
                    fmt.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
                }
                else -> {
                    Log.e(TAG, "Unknown mime type $mime")
                    return null
                }
            }

            format = fmt
            Log.d(TAG, "Format now ready: $fmt")
        }

        return transform(payload)
    }
}
