package com.swmansion.moqkit.publish.source

import android.content.Context
import android.util.Size
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.Observer
import com.swmansion.moqkit.publish.source.internal.GlFanOutRenderer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.ExecutionException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Camera lens selection. */
enum class CameraPosition { Front, Back }

/**
 * One explicitly owned CameraX capture, shared by one native preview and one publication.
 * Request CAMERA permission before [start]. [stop] releases hardware and allows restart;
 * [close] permanently disposes this capture. Neither preview nor publication starts hardware.
 */
class CameraCapture(
    private var position: CameraPosition = CameraPosition.Back,
    private val width: Int = 1920,
    private val height: Int = 1080,
    private val frameRate: Int = 30,
) : VideoFrameSource {
    // Surface attachment can be called synchronously by SurfaceHolder callbacks on Main.
    // This lock only protects GL references; never hold it across a Main dispatcher hop.
    private val surfaces = Any()
    private var glRenderer: GlFanOutRenderer? = null
    private var previewSurface: Surface? = null
    private var inputSurface: Surface? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var lifecycleOwner: LifecycleOwner? = null
    private var useCase: Preview? = null
    private var camera: Camera? = null
    private var cameraObserver: Observer<CameraState>? = null
    private val surfaceReturns = mutableListOf<CompletableDeferred<Unit>>()
    private var requestedRunning = false
    private var bindingID: Any? = null
    internal val captureLifecycle = CaptureLifecycle()

    val isCapturing: Boolean get() = captureLifecycle.snapshot.running

    suspend fun start(context: Context, lifecycleOwner: LifecycleOwner) {
        val caller = currentCoroutineContext()
        caller.ensureActive()
        var acquired = false
        try {
            PublishControl.run {
                caller.ensureActive()
                check(!captureLifecycle.snapshot.closed) { "Capture is closed" }
                if (requestedRunning) return@run
                acquired = true
                try {
                    cameraProvider = ProcessCameraProvider.getInstance(context.applicationContext).awaitResult()
                    this.lifecycleOwner = lifecycleOwner
                    synchronized(surfaces) {
                        val renderer = GlFanOutRenderer()
                        glRenderer = renderer
                        val texture = renderer.initialize()
                        texture.setDefaultBufferSize(width, height)
                        inputSurface = Surface(texture)
                        renderer.setPreviewSurface(previewSurface)
                    }
                    requestedRunning = true
                    bindCamera()
                    captureLifecycle.setRunning(true)
                } catch (e: Exception) {
                    stopOwned()
                    throw e
                }
            }
            caller.ensureActive()
        } catch (e: kotlinx.coroutines.CancellationException) {
            if (acquired) stop()
            throw e
        }
    }

    suspend fun stop() = PublishControl.run { stopOwned() }

    suspend fun close() = PublishControl.run {
        stopOwned()
        captureLifecycle.close()
        synchronized(surfaces) { previewSurface = null }
    }

    private suspend fun stopOwned() {
        requestedRunning = false
        captureLifecycle.setRunning(false)
        unbindCamera()
        synchronized(surfaces) {
            inputSurface?.release()
            inputSurface = null
            glRenderer?.release()
            glRenderer = null
        }
        cameraProvider = null
        lifecycleOwner = null
    }

    /** Switching while stopped changes the lens selected by the next start. */
    suspend fun switchCamera() = PublishControl.run {
        check(!captureLifecycle.snapshot.closed) { "Capture is closed" }
        position = if (position == CameraPosition.Front) CameraPosition.Back else CameraPosition.Front
        if (requestedRunning) {
            try {
                unbindCamera()
                bindCamera()
            } catch (e: Exception) {
                stopOwned()
                throw e
            }
        }
    }

    override fun attachEncoderSurface(surface: Surface) = synchronized(surfaces) {
        checkNotNull(glRenderer) { "Camera capture is not running" }.setEncoderSurface(surface)
    }

    override fun detachEncoderSurface() = synchronized(surfaces) {
        glRenderer?.setEncoderSurface(null)
        Unit
    }

    /** Borrow one preview surface. Detach completes before its owner may destroy it. */
    override fun setPreviewSurface(surface: Surface?) = synchronized(surfaces) {
        check(surface == null || !captureLifecycle.snapshot.closed) { "Capture is closed" }
        glRenderer?.setPreviewSurface(surface)
        previewSurface = surface
    }

    private suspend fun unbindCamera() {
        bindingID = null
        val returns = withContext(Dispatchers.Main.immediate) {
            cameraObserver?.let { camera?.cameraInfo?.cameraState?.removeObserver(it) }
            cameraObserver = null
            camera = null
            val previous = useCase
            useCase = null
            previous?.let { cameraProvider?.unbind(it) }
            surfaceReturns.toList().also { surfaceReturns.clear() }
        }
        // CameraX owns the input surface until every provideSurface result callback returns.
        returns.forEach { it.await() }
    }

    private suspend fun bindCamera() = withContext(Dispatchers.Main.immediate) {
        val provider = checkNotNull(cameraProvider)
        val owner = checkNotNull(lifecycleOwner)
        val surface = checkNotNull(inputSurface)
        val id = Any()
        bindingID = id
        @Suppress("DEPRECATION")
        val preview = Preview.Builder().setTargetResolution(Size(width, height)).build()
        useCase = preview
        preview.setSurfaceProvider { request ->
            if (useCase !== preview) {
                request.willNotProvideSurface()
            } else {
                val returned = CompletableDeferred<Unit>()
                surfaceReturns.add(returned)
                request.provideSurface(surface, Dispatchers.Default.asExecutor()) { returned.complete(Unit) }
            }
        }
        val selector = if (position == CameraPosition.Front)
            CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val boundCamera = provider.bindToLifecycle(owner, selector, preview)
        camera = boundCamera
        val observer = Observer<CameraState> { state ->
            PublishControl.post {
                if (bindingID === id && requestedRunning) {
                    when (state.type) {
                        CameraState.Type.OPEN -> captureLifecycle.setRunning(true)
                        CameraState.Type.CLOSED -> captureLifecycle.setRunning(false)
                        else -> Unit
                    }
                }
            }
        }
        cameraObserver = observer
        boundCamera.cameraInfo.cameraState.observeForever(observer)
    }
}

private suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.awaitResult(): T =
    suspendCancellableCoroutine { cont ->
        addListener({
            try { cont.resume(get()) }
            catch (e: ExecutionException) { cont.resumeWithException(e.cause ?: e) }
            catch (e: Exception) { cont.resumeWithException(e) }
        }, { command -> command.run() })
    }
