package com.swmansion.moqkit.subscribe.internal.playback

import uniffi.moq.MoqFrame

internal enum class MediaFrameKind {
    AUDIO,
    VIDEO,
}

internal interface MediaFrameObserver {
    fun onMediaFrame(frame: MoqFrame, kind: MediaFrameKind)

    fun onFrameDiscontinuity(kind: MediaFrameKind, gapUs: Long)
}

internal class CompositeMediaFrameObserver(
    private val observers: List<MediaFrameObserver>,
) : MediaFrameObserver {
    override fun onMediaFrame(frame: MoqFrame, kind: MediaFrameKind) {
        observers.forEach { it.onMediaFrame(frame, kind) }
    }

    override fun onFrameDiscontinuity(kind: MediaFrameKind, gapUs: Long) {
        observers.forEach { it.onFrameDiscontinuity(kind, gapUs) }
    }
}
