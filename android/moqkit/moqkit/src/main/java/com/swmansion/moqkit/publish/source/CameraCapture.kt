package com.swmansion.moqkit.publish.source

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import com.swmansion.moqkit.publish.source.internal.GlFanOutRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.ExecutionException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val TAG = "CameraCapture"

enum class CameraPosition { Front, Back }

class CameraCapture(
    private var position: CameraPosition = CameraPosition.Back,
    private val width: Int = 1920,
    private val height: Int = 1080,
    private val frameRate: Int = 30,
) : VideoFrameSource {

    private val glRenderer = GlFanOutRenderer()
    private var cameraSurface: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var lifecycleOwner: LifecycleOwner? = null

    suspend fun start(context: Context, lifecycleOwner: LifecycleOwner) {
        this.lifecycleOwner = lifecycleOwner
        val st = glRenderer.initialize()
        st.setDefaultBufferSize(width, height)
        cameraSurface = st
        inputSurface = Surface(st)

        cameraProvider = ProcessCameraProvider.getInstance(context).awaitResult()
        bindCamera()
    }

    fun stop() {
        cameraProvider?.unbindAll()
        inputSurface?.release()
        inputSurface = null
        cameraSurface = null
        glRenderer.release()
    }

    suspend fun switchCamera() {
        position = if (position == CameraPosition.Front) CameraPosition.Back else CameraPosition.Front
        bindCamera()
    }

    override fun attachEncoderSurface(surface: Surface) = glRenderer.setEncoderSurface(surface)
    override fun detachEncoderSurface() = glRenderer.setEncoderSurface(null)
    override fun setPreviewSurface(surface: Surface?) = glRenderer.setPreviewSurface(surface)

    private fun bindCamera() {
        val provider = cameraProvider ?: return
        val owner = lifecycleOwner ?: return
        val surface = inputSurface ?: return

        @Suppress("DEPRECATION")
        val preview = Preview.Builder()
            .setTargetResolution(Size(width, height))
            .build()

        preview.setSurfaceProvider { request ->
            request.provideSurface(surface, Dispatchers.IO.asExecutor()) { result ->
                Log.d(TAG, "Surface released: ${result.resultCode}")
            }
        }

        val selector = when (position) {
            CameraPosition.Front -> CameraSelector.DEFAULT_FRONT_CAMERA
            CameraPosition.Back -> CameraSelector.DEFAULT_BACK_CAMERA
        }

        provider.unbindAll()
        provider.bindToLifecycle(owner, selector, preview)
        Log.d(TAG, "Camera bound: $position ${width}x$height")
    }
}

private suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.awaitResult(): T =
    suspendCancellableCoroutine { cont ->
        addListener({
            try {
                cont.resume(get())
            } catch (e: ExecutionException) {
                cont.resumeWithException(e.cause ?: e)
            } catch (e: Exception) {
                cont.resumeWithException(e)
            }
        }, { command -> command.run() })
        cont.invokeOnCancellation { cancel(true) }
    }
