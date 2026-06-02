package com.swmansion.moqkit.publish.source

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import com.swmansion.moqkit.publish.source.internal.GlFanOutRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.ExecutionException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val MULTI_CAMERA_TAG = "MultiCameraCapture"

/**
 * Camera stream configuration used by [MultiCameraCapture].
 *
 * @property position Camera lens to bind for this stream.
 * @property width Requested capture width in pixels.
 * @property height Requested capture height in pixels.
 * @property frameRate Desired frame rate. Actual camera output is device and CameraX
 *   dependent.
 */
data class CameraStreamConfig(
    val position: CameraPosition,
    val width: Int = 1280,
    val height: Int = 720,
    val frameRate: Int = 30,
)

/**
 * CameraX-backed source for publishing front and back cameras concurrently.
 *
 * Apps must declare and request `CAMERA` permission before calling [start]. Check
 * [isSupported] before offering this mode in UI, then publish [frontSource] and
 * [backSource] as separate video tracks.
 */
class MultiCameraCapture(
    val front: CameraStreamConfig = CameraStreamConfig(position = CameraPosition.Front),
    val back: CameraStreamConfig = CameraStreamConfig(position = CameraPosition.Back),
) {
    private val frontRoute = CameraRoute(front, "front")
    private val backRoute = CameraRoute(back, "back")
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Video frames produced by the front-facing camera. */
    val frontSource: VideoFrameSource = frontRoute

    /** Video frames produced by the rear-facing camera. */
    val backSource: VideoFrameSource = backRoute

    private var cameraProvider: ProcessCameraProvider? = null
    private var running = false

    init {
        require(front.position == CameraPosition.Front) { "front stream must use CameraPosition.Front" }
        require(back.position == CameraPosition.Back) { "back stream must use CameraPosition.Back" }
        validateConfig(front)
        validateConfig(back)
    }

    /**
     * Starts concurrent front/back camera capture and binds it to [lifecycleOwner].
     */
    suspend fun start(context: Context, lifecycleOwner: LifecycleOwner) {
        withContext(Dispatchers.Main.immediate) {
            if (running) return@withContext

            check(isFrontBackSupported(context)) {
                "Concurrent front/back camera capture is not supported on this device"
            }

            frontRoute.initialize()
            backRoute.initialize()

            try {
                val provider = ProcessCameraProvider.getInstance(context).awaitResult()
                val cameraPair = provider.frontBackConcurrentPair()
                    ?: error("Concurrent front/back camera capture is not supported on this device")

                provider.unbindAll()
                provider.bindToLifecycle(
                    listOf(
                        ConcurrentCamera.SingleCameraConfig(
                            cameraPair.front.cameraSelector,
                            frontRoute.useCaseGroup(),
                            lifecycleOwner,
                        ),
                        ConcurrentCamera.SingleCameraConfig(
                            cameraPair.back.cameraSelector,
                            backRoute.useCaseGroup(),
                            lifecycleOwner,
                        ),
                    ),
                )
                cameraProvider = provider
                running = true
                Log.d(
                    MULTI_CAMERA_TAG,
                    "Multi-camera bound: ${front.width}x${front.height} + ${back.width}x${back.height}",
                )
            } catch (e: Exception) {
                releaseRoutes()
                throw e
            }
        }
    }

    /**
     * Stops concurrent camera capture and releases camera resources.
     */
    fun stop() {
        val provider = cameraProvider
        cameraProvider = null
        running = false

        if (provider == null || Looper.myLooper() == Looper.getMainLooper()) {
            try {
                provider?.unbindAll()
            } catch (e: Exception) {
                Log.w(MULTI_CAMERA_TAG, "Camera unbind failed: $e")
            } finally {
                releaseRoutes()
                Log.d(MULTI_CAMERA_TAG, "Multi-camera stopped")
            }
            return
        }

        mainHandler.post {
            try {
                provider.unbindAll()
            } catch (e: Exception) {
                Log.w(MULTI_CAMERA_TAG, "Camera unbind failed: $e")
            } finally {
                releaseRoutes()
                Log.d(MULTI_CAMERA_TAG, "Multi-camera stopped")
            }
        }
    }

    private fun releaseRoutes() {
        frontRoute.release()
        backRoute.release()
    }

    private fun validateConfig(config: CameraStreamConfig) {
        require(config.width > 0) { "camera width must be greater than zero" }
        require(config.height > 0) { "camera height must be greater than zero" }
        require(config.frameRate > 0) { "camera frameRate must be greater than zero" }
    }

    companion object {
        /**
         * Whether Android reports concurrent camera support for the current device.
         *
         * This is a fast package-manager capability check. Use [isFrontBackSupported] when
         * the app specifically needs to know whether CameraX exposes a front/back pair that
         * can be bound concurrently.
         */
        fun isSupported(context: Context): Boolean =
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)

        /**
         * Whether CameraX exposes a front/back pair that can be bound concurrently.
         */
        suspend fun isFrontBackSupported(context: Context): Boolean =
            isSupported(context)
                && withContext(Dispatchers.Main.immediate) {
                    ProcessCameraProvider.getInstance(context)
                        .awaitResult()
                        .hasFrontBackConcurrentPair()
                }
    }

    private class CameraRoute(
        private val config: CameraStreamConfig,
        private val label: String,
    ) : VideoFrameSource {
        private var glRenderer = GlFanOutRenderer()
        private var inputSurface: Surface? = null
        private var previewSurface: Surface? = null
        private var encoderSurface: Surface? = null
        private var initialized = false

        fun initialize() {
            if (initialized) return

            val surfaceTexture: SurfaceTexture = glRenderer.initialize()
            surfaceTexture.setDefaultBufferSize(config.width, config.height)
            inputSurface = Surface(surfaceTexture)
            initialized = true

            previewSurface?.let { glRenderer.setPreviewSurface(it) }
            encoderSurface?.let { glRenderer.setEncoderSurface(it) }
        }

        fun release() {
            if (!initialized) return

            inputSurface?.release()
            inputSurface = null
            encoderSurface = null
            glRenderer.release()
            glRenderer = GlFanOutRenderer()
            initialized = false
        }

        override fun attachEncoderSurface(surface: Surface) {
            encoderSurface = surface
            if (initialized) {
                glRenderer.setEncoderSurface(surface)
            }
        }

        override fun detachEncoderSurface() {
            encoderSurface = null
            if (initialized) {
                glRenderer.setEncoderSurface(null)
            }
        }

        override fun setPreviewSurface(surface: Surface?) {
            previewSurface = surface
            if (initialized) {
                glRenderer.setPreviewSurface(surface)
            }
        }

        fun useCaseGroup(): UseCaseGroup {
            val surface = inputSurface ?: error("$label camera route is not initialized")

            @Suppress("DEPRECATION")
            val preview = Preview.Builder()
                .setTargetResolution(Size(config.width, config.height))
                .setTargetFrameRate(Range(config.frameRate, config.frameRate))
                .build()

            preview.setSurfaceProvider { request ->
                request.provideSurface(surface, Dispatchers.IO.asExecutor()) { result ->
                    Log.d(MULTI_CAMERA_TAG, "$label surface released: ${result.resultCode}")
                }
            }

            return UseCaseGroup.Builder()
                .addUseCase(preview)
                .build()
        }
    }
}

private data class FrontBackCameraPair(
    val front: CameraInfo,
    val back: CameraInfo,
)

private fun ProcessCameraProvider.hasFrontBackConcurrentPair(): Boolean =
    frontBackConcurrentPair() != null

private fun ProcessCameraProvider.frontBackConcurrentPair(): FrontBackCameraPair? =
    availableConcurrentCameraInfos.firstNotNullOfOrNull { cameraInfos ->
        val front = CameraSelector.DEFAULT_FRONT_CAMERA.safeFilter(cameraInfos).firstOrNull()
        val back = CameraSelector.DEFAULT_BACK_CAMERA.safeFilter(cameraInfos).firstOrNull()
        if (front != null && back != null) {
            FrontBackCameraPair(front = front, back = back)
        } else {
            null
        }
    }

private fun CameraSelector.safeFilter(cameraInfos: List<CameraInfo>): List<CameraInfo> =
    try {
        filter(cameraInfos)
    } catch (_: Exception) {
        emptyList()
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
