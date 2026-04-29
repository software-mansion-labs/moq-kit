package com.swmansion.moqkit.subscribe.internal.playback

import android.util.Log
import com.swmansion.moqkit.subscribe.internal.codec.H264SpsParser

private const val H264_SPS_REWRITER_TAG = "H264SpsRewriter"
private const val H264_MAX_NUM_REORDER_FRAMES_OVERRIDE = 0

internal object H264SpsRewriter {
    fun rewriteSps(sps: ByteArray): ByteArray {
        val original = H264SpsParser.parseMaxNumReorderFrames(sps)
        val rewritten = H264SpsParser.overrideMaxNumReorderFrames(
            sps,
            H264_MAX_NUM_REORDER_FRAMES_OVERRIDE,
        )
        if (rewritten == null) {
            Log.w(H264_SPS_REWRITER_TAG, "H.264 SPS max_num_reorder_frames override failed; preserving original SPS")
            logMaxNumReorderFrames("original", original)
            return sps
        }

        val patched = H264SpsParser.parseMaxNumReorderFrames(rewritten)
        Log.d(H264_SPS_REWRITER_TAG, "H.264 SPS max_num_reorder_frames override: $original -> $patched")
        return rewritten
    }

    fun rewriteAnnexBStream(payload: ByteArray): ByteArray {
        val rewritten = H264SpsParser.overrideMaxNumReorderFramesInAnnexBStream(
            payload,
            H264_MAX_NUM_REORDER_FRAMES_OVERRIDE,
        )
        if (rewritten == null) {
            Log.w(H264_SPS_REWRITER_TAG, "H.264 in-band SPS override failed; preserving original payload")
            return payload
        }
        return rewritten
    }

    private fun logMaxNumReorderFrames(label: String, value: Int?) {
        if (value != null) {
            Log.d(H264_SPS_REWRITER_TAG, "H.264 SPS $label max_num_reorder_frames=$value")
        } else {
            Log.d(H264_SPS_REWRITER_TAG, "H.264 SPS $label max_num_reorder_frames unavailable")
        }
    }
}
