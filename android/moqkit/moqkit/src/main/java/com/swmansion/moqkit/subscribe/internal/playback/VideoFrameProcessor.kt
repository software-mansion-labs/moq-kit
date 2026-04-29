package com.swmansion.moqkit.subscribe.internal.playback

import android.media.MediaFormat
import android.util.Log
import uniffi.moq.MoqVideo

private const val TAG = "VideoFrameProcessor"

/**
 * Selects the right payload transform and CSD extraction strategy based on the video config.
 *
 * Payload conversion is delegated to [VideoPayloadTransformBuilder]. CSD is either parsed from the
 * codec description up front or extracted in-band from the first keyframe containing parameter sets.
 *
 * Consumers call [processPayload] and get back ready-to-decode Annex B bytes.
 */
internal class VideoFrameProcessor(private val config: MoqVideo) {

    private val transform = VideoPayloadTransformBuilder.from(config)

    @Volatile
    private var format: MediaFormat? = null

    /** True once a MediaFormat with CSD is available and the decoder can be configured. */
    val isReady: Boolean get() = format != null

    init {
        if (config.description != null) {
            format = VideoMediaFormatFactory.from(config)
            if (format != null) {
                Log.d(TAG, "Format ready immediately: $format")
            } else {
                Log.w(TAG, "VideoMediaFormatFactory.from returned null for codec=${config.codec}")
            }

            format?.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format?.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
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

            val fmt = VideoMediaFormatFactory.from(config, payload)
            if (fmt == null) {
                Log.d(TAG, "Keyframe lacks codec configuration for codec=${config.codec}")
                return null
            }

            format = fmt
            // format?.setInteger(MediaFormat.KEY_PRIORITY, 0)
            // format?.setInteger(MediaFormat.KEY_LATENCY, 1)
            // format?.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            // format?.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // format?.setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 1)
            // format?.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            // format?.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // format?.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            Log.d(TAG, "Format now ready: $fmt")
        }

        return transform.apply(payload)
    }
}
