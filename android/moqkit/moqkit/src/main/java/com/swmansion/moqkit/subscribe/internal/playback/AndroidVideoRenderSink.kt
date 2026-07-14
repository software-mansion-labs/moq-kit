package com.swmansion.moqkit.subscribe.internal.playback

import com.swmansion.moqkit.subscribe.internal.pipeline.DecodedFrame
import com.swmansion.moqkit.subscribe.internal.pipeline.RenderSink

internal interface VideoOutputSession {
    fun renderOutput(index: Int, atNanos: Long): Boolean
    fun dropOutput(index: Int): Boolean
}

/** Android MediaCodec output adapter; scheduling policy remains in the pure core. */
internal class AndroidVideoRenderSink(
    private val session: () -> VideoOutputSession?,
) : RenderSink {
    override fun render(frame: DecodedFrame, atNanos: Long): Boolean {
        val index = frame.handle as? Int ?: return false
        return session()?.renderOutput(index, atNanos) == true
    }

    override fun drop(frame: DecodedFrame) {
        val index = frame.handle as? Int ?: return
        session()?.dropOutput(index)
    }
}
