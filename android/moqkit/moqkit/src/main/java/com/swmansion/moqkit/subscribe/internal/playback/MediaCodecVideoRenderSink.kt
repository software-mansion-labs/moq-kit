package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.pipeline.DecodedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.RenderSink

internal interface VideoOutputSession {
    fun renderOutput(index: Int, atNanos: Long): Boolean
    fun dropOutput(index: Int): Boolean
}

internal data class VideoOutputHandle(
    val session: VideoOutputSession,
    val index: Int,
)

/**
 * Translates pure-core scheduling decisions into timed MediaCodec output-buffer releases.
 * Rendering policy remains in the scheduler; this adapter only applies that decision to the
 * decoder session that owns each output buffer.
 */
internal class MediaCodecVideoRenderSink : RenderSink {
    override fun render(frame: DecodedFrame, atNanos: Long): Boolean {
        val handle = frame.handle as? VideoOutputHandle ?: return false
        return handle.session.renderOutput(handle.index, atNanos)
    }

    override fun drop(frame: DecodedFrame) {
        val handle = frame.handle as? VideoOutputHandle ?: return
        handle.session.dropOutput(handle.index)
    }
}
