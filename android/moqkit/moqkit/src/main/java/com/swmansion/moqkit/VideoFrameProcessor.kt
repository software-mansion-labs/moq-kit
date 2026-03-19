package com.swmansion.moqkit

import android.media.MediaFormat
import android.util.Log
import uniffi.moq.MoqVideo
import java.nio.ByteBuffer

private const val TAG = "VideoFrameProcessor"

/**
 * Selects the right payload transform and CSD extraction strategy based on the video codec.
 *
 * - AVC1/HEV1/HVC1: AVCC length-prefixed payloads → convert to Annex B; CSD from config record.
 * - AVC3 with description: payloads are already Annex B → passthrough; CSD from config record.
 * - AVC3 without description: payloads are already Annex B → passthrough; CSD extracted in-band
 *   from the first keyframe containing SPS/PPS.
 *
 * Consumers call [processPayload] and get back ready-to-decode Annex B bytes.
 */
internal class VideoFrameProcessor(private val config: MoqVideo) {

    private val transform: (ByteArray) -> ByteArray
    private var format: MediaFormat? = null

    /** True once a MediaFormat with CSD is available and the decoder can be configured. */
    val isReady: Boolean get() = format != null

    init {
        val codec = config.codec.lowercase()
        val isAvc3 = codec.startsWith("avc3")

        transform = if (isAvc3) { payload -> payload } else { payload -> payload.avccToAnnexB() }

        if (isAvc3 && config.description == null) {
            // Deferred: will extract SPS/PPS from the first keyframe
            Log.d(TAG, "AVC3 stream without description — deferring CSD extraction")
        } else {
            // Immediate: build format from config record
            format = MediaFactory.makeVideoFormat(config)
            if (format != null) {
                Log.d(TAG, "Format ready immediately: ${format}")
            } else {
                Log.w(TAG, "makeVideoFormat returned null for codec=${config.codec}")
            }
        }
    }

    /** Returns the MediaFormat once CSD is available, null otherwise. */
    fun getFormat(): MediaFormat? = format

    /**
     * Process a compressed video frame payload.
     *
     * @return Annex B bytes ready for MediaCodec, or null if the frame should be dropped
     *         (e.g., waiting for a keyframe with SPS/PPS).
     */
    fun processPayload(payload: ByteArray, keyframe: Boolean): ByteArray? {
        if (!isReady) {
            if (!keyframe) return null // Can't extract CSD from non-keyframe

            val params = AnnexBUtils.extractParameterSets(payload)
            if (params == null) {
                Log.d(TAG, "Keyframe lacks SPS/PPS, dropping")
                return null
            }

            Log.d(TAG, "Extracted in-band SPS (${params.sps.size}B) + PPS (${params.pps.size}B)")
            val mime = MediaFormat.MIMETYPE_VIDEO_AVC
            val width = config.coded?.width?.toInt() ?: 1920
            val height = config.coded?.height?.toInt() ?: 1080
            val fmt = MediaFormat.createVideoFormat(mime, width, height)
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(params.sps))
            fmt.setByteBuffer("csd-1", ByteBuffer.wrap(params.pps))
            format = fmt
            Log.d(TAG, "AVC3 format now ready: $fmt")
        }

        return transform(payload)
    }
}
