package com.swmansion.moqkit.publish.source

import android.view.Surface

interface VideoFrameSource {
    fun attachEncoderSurface(surface: Surface)
    fun detachEncoderSurface()
    fun setPreviewSurface(surface: Surface?)
}

interface AudioFrameSource {
    var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)?
}
