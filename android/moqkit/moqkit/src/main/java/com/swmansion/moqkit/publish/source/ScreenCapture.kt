package com.swmansion.moqkit.publish.source

import android.content.Context
import android.content.Intent
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.publish.source.internal.GlFanOutRenderer

private const val TAG = "ScreenCapture"

class ScreenCapture(
    private val intent: Intent,
    private val resultCode: Int,
    val width: Int,
    val height: Int,
    private val frameRate: Int = 30,
) : VideoFrameSource {

    private val glRenderer = GlFanOutRenderer()
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var inputSurface: Surface? = null

    suspend fun start(context: Context) {
        val st: SurfaceTexture = glRenderer.initialize()
        st.setDefaultBufferSize(width, height)
        inputSurface = Surface(st)

        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = manager.getMediaProjection(resultCode, intent)
        projection = proj

        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stop() }
        }, null)

        virtualDisplay = proj.createVirtualDisplay(
            "ScreenCapture",
            width, height,
            context.resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null, null,
        )
        Log.d(TAG, "Screen capture started ${width}x$height")
    }

    fun stop() {
        virtualDisplay?.release()
        virtualDisplay = null
        val proj = projection
        projection = null
        proj?.stop()
        inputSurface?.release()
        inputSurface = null
        glRenderer.release()
        Log.d(TAG, "Screen capture stopped")
    }

    override fun attachEncoderSurface(surface: Surface) = glRenderer.setEncoderSurface(surface)
    override fun detachEncoderSurface() = glRenderer.setEncoderSurface(null)
    override fun setPreviewSurface(surface: Surface?) = glRenderer.setPreviewSurface(surface)
}
