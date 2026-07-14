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

/** Android MediaCodec output adapter; scheduling policy remains in the pure core. */
internal class AndroidVideoRenderSink : RenderSink {
    override fun render(frame: DecodedFrame, atNanos: Long): Boolean {
        val handle = frame.handle as? VideoOutputHandle ?: return false
        return handle.session.renderOutput(handle.index, atNanos)
    }

    override fun drop(frame: DecodedFrame) {
        val handle = frame.handle as? VideoOutputHandle ?: return
        handle.session.dropOutput(handle.index)
    }
}
