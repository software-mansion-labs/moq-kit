package com.swmansion.moqkit.publish.source

import android.view.Surface

/**
 * Advanced extension point for custom video capture sources.
 *
 * Most apps should use [CameraCapture], [MultiCameraCapture], or [ScreenCapture]. Implement
 * this interface only when the app needs to feed frames from its own rendering or capture
 * pipeline.
 */
interface VideoFrameSource {
    /**
     * Connects the source to the encoder input surface.
     *
     * [com.swmansion.moqkit.publish.Publisher] calls this when a video track starts.
     * Sources that assign presentation timestamps explicitly must use the monotonic
     * [System.nanoTime] timebase so audio and video remain comparable. Leaving timestamps
     * automatic on an Android [Surface] already uses that timebase.
     */
    fun attachEncoderSurface(surface: Surface)

    /**
     * Disconnects the encoder surface.
     *
     * [com.swmansion.moqkit.publish.Publisher] calls this when a video track stops.
     */
    fun detachEncoderSurface()

    /**
     * Sets an optional preview surface for local display.
     *
     * Pass `null` to clear the preview.
     */
    fun setPreviewSurface(surface: Surface?)
}

/**
 * Advanced extension point for custom audio capture sources.
 *
 * Most apps should use [MicrophoneCapture]. Implement this interface only when the app
 * needs to publish PCM samples from another source.
 */
interface AudioFrameSource {
    /**
     * Callback that receives PCM 16-bit audio samples.
     *
     * [com.swmansion.moqkit.publish.Publisher] sets this when an audio track starts and
     * clears it when the track stops. The timestamp is the first sample's capture time in
     * microseconds using the monotonic [System.nanoTime] timebase.
     */
    var onPcmData: ((data: ByteArray, size: Int, timestampUs: Long) -> Unit)?
}
