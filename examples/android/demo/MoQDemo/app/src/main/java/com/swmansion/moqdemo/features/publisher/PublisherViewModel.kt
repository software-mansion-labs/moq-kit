package com.swmansion.moqdemo.features.publisher

import android.app.Application
import android.content.Intent
import android.view.Surface
import androidx.core.content.ContextCompat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.publish.Publisher
import com.swmansion.moqkit.publish.PublishedTrack
import com.swmansion.moqkit.publish.PublishedTrackState
import com.swmansion.moqkit.publish.PublisherEvent
import com.swmansion.moqkit.publish.PublisherState
import com.swmansion.moqkit.publish.encoder.AudioCodec
import com.swmansion.moqkit.publish.encoder.AudioEncoderConfig
import com.swmansion.moqkit.publish.encoder.VideoCodec
import com.swmansion.moqkit.publish.encoder.VideoEncoderConfig
import com.swmansion.moqkit.publish.source.CameraCapture
import com.swmansion.moqkit.publish.source.CameraPosition
import com.swmansion.moqkit.publish.source.CameraStreamConfig
import com.swmansion.moqkit.publish.source.MicrophoneCapture
import com.swmansion.moqkit.publish.source.MultiCameraCapture
import com.swmansion.moqkit.publish.source.ScreenCapture
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

enum class VideoResolution(val label: String, val width: Int, val height: Int) {
    HD("720p", 1280, 720),
    FHD("1080p", 1920, 1080),
}

enum class VideoFrameRate(val label: String, val fps: Int) {
    FPS24("24", 24),
    FPS30("30", 30),
    FPS60("60", 60),
}

enum class CameraSourceMode(val label: String) {
    SingleCamera("Single"),
    MultiCamera("MultiCam"),
}

class PublisherViewModel(application: Application) : AndroidViewModel(application) {

    // Connection settings
    var broadcastPath by mutableStateOf("live/test")

    // Source toggles
    var cameraEnabled by mutableStateOf(true)
    var micEnabled by mutableStateOf(true)
    var screenEnabled by mutableStateOf(false)
    var cameraSourceMode by mutableStateOf(CameraSourceMode.SingleCamera)
    var cameraPosition by mutableStateOf(CameraPosition.Front)
    var multiCameraMainPreviewPosition by mutableStateOf(CameraPosition.Back)

    // Codec settings
    var videoCodec by mutableStateOf(VideoCodec.H264)
    var audioCodec by mutableStateOf(AudioCodec.AAC)
    var videoResolution by mutableStateOf(VideoResolution.HD)
    var videoFrameRate by mutableStateOf(VideoFrameRate.FPS30)
    var audioSampleRate by mutableStateOf(48_000)

    // Observable state
    var sessionState by mutableStateOf<Session.State>(Session.State.Idle)
    var publisherState by mutableStateOf<PublisherState>(PublisherState.Idle)
    val trackStates = mutableStateMapOf<String, PublishedTrackState>()
    var publishedTracks by mutableStateOf<List<PublishedTrack>>(emptyList())
    var lastError by mutableStateOf<String?>(null)

    val supportedVideoCodecs: List<VideoCodec>
        get() = VideoEncoderConfig.supportedCodecs()

    val supportedAudioCodecs: List<AudioCodec>
        get() = AudioEncoderConfig.supportedCodecs()

    var isMultiCameraSupported by mutableStateOf(MultiCameraCapture.isSupported(getApplication()))
        private set

    val isPublishing get() = publisherState == PublisherState.Publishing
    val canPublish get() = sessionState == Session.State.Idle
            && publisherState == PublisherState.Idle
            && (cameraEnabled || micEnabled || screenEnabled)
            && publishUnsupportedReason() == null
    val canStop get() = isPublishing || sessionState == Session.State.Connecting
            || sessionState == Session.State.Connected

    val stateLabel get() = when (val s = sessionState) {
        Session.State.Idle -> "idle"
        Session.State.Connecting -> "connecting…"
        Session.State.Connected -> "connected"
        is Session.State.Error -> "error: ${s.message}"
        Session.State.Closed -> "closed"
    }

    val publisherStateLabel get() = when (val s = publisherState) {
        PublisherState.Idle -> "idle"
        PublisherState.Publishing -> "publishing"
        PublisherState.Stopped -> "stopped"
        is PublisherState.Error -> "error: ${s.message}"
    }

    // Internal state
    private var session: Session? = null
    private var publisher: Publisher? = null
    private var camera: CameraCapture? = null
    private var multiCamera: MultiCameraCapture? = null
    private var microphone: MicrophoneCapture? = null
    private var screenCapture: ScreenCapture? = null
    private var screenProjectionData: Pair<Int, Intent>? = null
    private var previewSurface: Surface? = null
    private var frontPreviewSurface: Surface? = null
    private var backPreviewSurface: Surface? = null
    private var sessionJob: Job? = null
    private var publisherJobs = mutableListOf<Job>()

    init {
        if (videoCodec !in supportedVideoCodecs) {
            videoCodec = supportedVideoCodecs.firstOrNull() ?: videoCodec
        }
        if (audioCodec !in supportedAudioCodecs) {
            audioCodec = supportedAudioCodecs.firstOrNull() ?: audioCodec
        }
        refreshMultiCameraSupport()
    }

    fun refreshMultiCameraSupport() {
        if (!MultiCameraCapture.isSupported(getApplication())) {
            isMultiCameraSupported = false
            if (cameraSourceMode == CameraSourceMode.MultiCamera) {
                cameraSourceMode = CameraSourceMode.SingleCamera
            }
            return
        }

        viewModelScope.launch {
            val supported = try {
                MultiCameraCapture.isFrontBackSupported(getApplication())
            } catch (_: Exception) {
                false
            }
            isMultiCameraSupported = supported
            if (!supported && cameraSourceMode == CameraSourceMode.MultiCamera) {
                lastError = "Multi-camera capture is not supported by this emulator/device"
                cameraSourceMode = CameraSourceMode.SingleCamera
            }
        }
    }

    fun setPreviewSurface(surface: Surface?) {
        previewSurface = surface
        camera?.setPreviewSurface(surface)
    }

    fun setMultiCameraPreviewSurface(position: CameraPosition, surface: Surface?) {
        when (position) {
            CameraPosition.Front -> {
                frontPreviewSurface = surface
                multiCamera?.frontSource?.setPreviewSurface(surface)
            }
            CameraPosition.Back -> {
                backPreviewSurface = surface
                multiCamera?.backSource?.setPreviewSurface(surface)
            }
        }
    }

    fun startCamera(lifecycleOwner: LifecycleOwner) {
        if (!cameraEnabled) return

        when (cameraSourceMode) {
            CameraSourceMode.SingleCamera -> startSingleCamera(lifecycleOwner)
            CameraSourceMode.MultiCamera -> startMultiCamera(lifecycleOwner)
        }
    }

    private fun startSingleCamera(lifecycleOwner: LifecycleOwner) {
        stopMultiCamera()
        if (camera != null) return

        val cam = CameraCapture(position = cameraPosition)
        camera = cam
        viewModelScope.launch {
            try {
                cam.start(getApplication(), lifecycleOwner)
                cam.setPreviewSurface(previewSurface)
            } catch (e: Exception) {
                lastError = "Camera start failed: ${e.message}"
                camera = null
            }
        }
    }

    private fun startMultiCamera(lifecycleOwner: LifecycleOwner) {
        if (!isMultiCameraSupported) {
            lastError = "Multi-camera capture is not supported on this device"
            cameraSourceMode = CameraSourceMode.SingleCamera
            startSingleCamera(lifecycleOwner)
            return
        }

        stopSingleCamera()

        val videoConfig = currentVideoConfig()
        val existing = multiCamera
        if (existing != null && isMultiCamera(existing, videoConfig)) {
            return
        }

        stopMultiCamera()

        val capture = makeMultiCameraCapture(videoConfig)
        applyMultiCameraPreviewSurfaces(capture)
        multiCamera = capture

        viewModelScope.launch {
            try {
                if (!MultiCameraCapture.isFrontBackSupported(getApplication())) {
                    error("No concurrent front/back camera pair is available on this emulator/device")
                }
                capture.start(getApplication(), lifecycleOwner)
            } catch (e: Exception) {
                if (multiCamera === capture) {
                    lastError = "Multi-camera start failed: ${e.message}"
                    multiCamera = null
                    isMultiCameraSupported = false
                    cameraSourceMode = CameraSourceMode.SingleCamera
                    startSingleCamera(lifecycleOwner)
                }
                capture.stop()
            }
        }
    }

    fun stopCamera() {
        stopSingleCamera()
        stopMultiCamera()
    }

    fun flipCamera() {
        if (cameraSourceMode != CameraSourceMode.SingleCamera) return

        cameraPosition = if (cameraPosition == CameraPosition.Front) CameraPosition.Back else CameraPosition.Front
        viewModelScope.launch {
            try {
                camera?.switchCamera()
            } catch (e: Exception) {
                lastError = "Camera flip failed: ${e.message}"
            }
        }
    }

    fun swapMultiCameraPreview() {
        multiCameraMainPreviewPosition =
            if (multiCameraMainPreviewPosition == CameraPosition.Front) {
                CameraPosition.Back
            } else {
                CameraPosition.Front
            }
    }

    fun setScreenProjection(resultCode: Int, intent: Intent) {
        screenProjectionData = Pair(resultCode, intent)
    }

    fun clearScreenProjection() {
        screenProjectionData = null
    }

    fun selectAudioCodec(codec: AudioCodec) {
        audioCodec = codec
        if (codec == AudioCodec.OPUS && audioSampleRate != 48_000) {
            audioSampleRate = 48_000
        }
    }

    fun publish(lifecycleOwner: LifecycleOwner, relayUrl: String) {
        lastError = null
        trackStates.clear()
        publishedTracks = emptyList()

        val url = relayUrl.trim()
        if (url.isEmpty()) {
            lastError = "Relay URL is required"
            return
        }

        val videoConfig = currentVideoConfig()
        val audioConfig = currentAudioConfig()
        publishUnsupportedReason(videoConfig, audioConfig)?.let {
            lastError = it
            return
        }

        val s = Session(url = url, parentScope = viewModelScope)
        session = s

        sessionJob = s.state.onEach { sessionState = it }.launchIn(viewModelScope)

        viewModelScope.launch {
            try {
                s.connect()

                val pub = Publisher()
                publisher = pub

                val tracks = mutableListOf<PublishedTrack>()

                if (cameraEnabled) {
                    when (cameraSourceMode) {
                        CameraSourceMode.SingleCamera -> {
                            val cam = camera ?: CameraCapture(position = cameraPosition).also {
                                it.start(getApplication(), lifecycleOwner)
                                it.setPreviewSurface(previewSurface)
                                camera = it
                            }
                            tracks += pub.addVideoTrack(name = "camera", source = cam, config = videoConfig)
                            trackStates["camera"] = PublishedTrackState.Idle
                        }

                        CameraSourceMode.MultiCamera -> {
                            val capture = runningMultiCameraCapture(videoConfig, lifecycleOwner)
                            tracks += pub.addVideoTrack(
                                name = "front-camera",
                                source = capture.frontSource,
                                config = videoConfig,
                            )
                            trackStates["front-camera"] = PublishedTrackState.Idle

                            tracks += pub.addVideoTrack(
                                name = "back-camera",
                                source = capture.backSource,
                                config = videoConfig,
                            )
                            trackStates["back-camera"] = PublishedTrackState.Idle
                        }
                    }
                }

                if (micEnabled) {
                    val mic = MicrophoneCapture(sampleRate = audioSampleRate)
                    microphone = mic
                    mic.start()
                    tracks += pub.addAudioTrack(name = "mic", source = mic, config = audioConfig)
                    trackStates["mic"] = PublishedTrackState.Idle
                }

                if (screenEnabled) {
                    val (resultCode, intent) = screenProjectionData
                        ?: error("Screen capture permission not granted. Toggle screen capture off and on again.")
                    ContextCompat.startForegroundService(
                        getApplication<Application>(),
                        Intent(getApplication(), ScreenCaptureService::class.java)
                    )
                    withTimeout(5_000) {
                        ScreenCaptureService.awaitStarted()
                    }
                    val screen = ScreenCapture(
                        intent = intent,
                        resultCode = resultCode,
                        width = videoResolution.width,
                        height = videoResolution.height,
                        frameRate = videoFrameRate.fps,
                    )
                    screenCapture = screen
                    screen.start(getApplication())
                    tracks += pub.addVideoTrack(name = "screen", source = screen, config = videoConfig)
                    trackStates["screen"] = PublishedTrackState.Idle
                }

                publishedTracks = tracks
                s.publish(broadcastPath, pub)
                pub.start()

                observePublisher(pub, tracks)
            } catch (e: Exception) {
                lastError = e.message ?: "Unknown error"
                resetAfterPublishFailure()
            }
        }
    }

    fun stop() {
        stopPublishing(keepCameraPreview = true)
    }

    private fun stopPublishing(keepCameraPreview: Boolean) {
        publisherJobs.forEach { it.cancel() }
        publisherJobs.clear()
        sessionJob?.cancel()
        sessionJob = null

        val pub = publisher
        val sess = session

        publisher = null
        session = null
        publishedTracks = emptyList()
        trackStates.clear()
        publisherState = PublisherState.Idle
        sessionState = Session.State.Idle

        viewModelScope.launch {
            pub?.stop()
            sess?.close()
        }

        cleanupSources(keepCameraPreview = keepCameraPreview)
    }

    override fun onCleared() {
        super.onCleared()
        stopPublishing(keepCameraPreview = false)
    }

    private fun resetAfterPublishFailure() {
        publisherJobs.forEach { it.cancel() }
        publisherJobs.clear()
        sessionJob?.cancel()
        sessionJob = null

        val pub = publisher
        val sess = session

        publisher = null
        session = null
        publishedTracks = emptyList()
        trackStates.clear()
        publisherState = PublisherState.Idle
        sessionState = Session.State.Idle

        viewModelScope.launch {
            try {
                pub?.stop()
            } catch (_: Exception) {}
            try {
                sess?.close()
            } catch (_: Exception) {}
        }

        cleanupSources(keepCameraPreview = false)
    }

    private fun cleanupSources(keepCameraPreview: Boolean) {
        microphone?.stop()
        microphone = null
        screenCapture?.stop()
        screenCapture = null
        getApplication<Application>().stopService(
            Intent(getApplication(), ScreenCaptureService::class.java)
        )
        if (!keepCameraPreview) {
            stopCamera()
        }
    }

    private fun stopSingleCamera() {
        camera?.stop()
        camera = null
    }

    private fun stopMultiCamera() {
        multiCamera?.stop()
        multiCamera = null
    }

    private suspend fun runningMultiCameraCapture(
        videoConfig: VideoEncoderConfig,
        lifecycleOwner: LifecycleOwner,
    ): MultiCameraCapture {
        check(isMultiCameraSupported) {
            "Multi-camera capture is not supported on this device"
        }
        check(MultiCameraCapture.isFrontBackSupported(getApplication())) {
            "No concurrent front/back camera pair is available on this emulator/device"
        }

        val existing = multiCamera
        if (existing != null && isMultiCamera(existing, videoConfig)) {
            existing.start(getApplication(), lifecycleOwner)
            return existing
        }

        stopMultiCamera()

        val capture = makeMultiCameraCapture(videoConfig)
        applyMultiCameraPreviewSurfaces(capture)
        multiCamera = capture
        try {
            capture.start(getApplication(), lifecycleOwner)
            return capture
        } catch (e: Exception) {
            if (multiCamera === capture) {
                multiCamera = null
            }
            capture.stop()
            throw e
        }
    }

    private fun makeMultiCameraCapture(videoConfig: VideoEncoderConfig): MultiCameraCapture =
        MultiCameraCapture(
            front = CameraStreamConfig(
                position = CameraPosition.Front,
                width = videoConfig.width,
                height = videoConfig.height,
                frameRate = videoConfig.frameRate,
            ),
            back = CameraStreamConfig(
                position = CameraPosition.Back,
                width = videoConfig.width,
                height = videoConfig.height,
                frameRate = videoConfig.frameRate,
            ),
        )

    private fun applyMultiCameraPreviewSurfaces(capture: MultiCameraCapture) {
        capture.frontSource.setPreviewSurface(frontPreviewSurface)
        capture.backSource.setPreviewSurface(backPreviewSurface)
    }

    private fun isMultiCamera(
        capture: MultiCameraCapture,
        videoConfig: VideoEncoderConfig,
    ): Boolean =
        capture.front.width == videoConfig.width
            && capture.front.height == videoConfig.height
            && capture.front.frameRate == videoConfig.frameRate
            && capture.back.width == videoConfig.width
            && capture.back.height == videoConfig.height
            && capture.back.frameRate == videoConfig.frameRate

    private fun currentVideoConfig(): VideoEncoderConfig = VideoEncoderConfig(
        codec = videoCodec,
        width = videoResolution.width,
        height = videoResolution.height,
        frameRate = videoFrameRate.fps,
    )

    private fun currentAudioConfig(): AudioEncoderConfig = AudioEncoderConfig(
        codec = audioCodec,
        sampleRate = audioSampleRate,
    )

    private fun publishUnsupportedReason(
        videoConfig: VideoEncoderConfig = currentVideoConfig(),
        audioConfig: AudioEncoderConfig = currentAudioConfig(),
    ): String? {
        if (cameraEnabled && cameraSourceMode == CameraSourceMode.MultiCamera && !isMultiCameraSupported) {
            return "Multi-camera capture is not supported on this device"
        }
        if ((cameraEnabled || screenEnabled) && !videoConfig.isSupported) {
            return videoConfig.unsupportedReason ?: "Selected video codec is not supported"
        }
        if (micEnabled && !audioConfig.isSupported) {
            return audioConfig.unsupportedReason ?: "Selected audio codec is not supported"
        }
        return null
    }

    private fun observePublisher(pub: Publisher, tracks: List<PublishedTrack>) {
        publisherJobs += pub.state.onEach { publisherState = it }.launchIn(viewModelScope)

        publisherJobs += pub.events.onEach { event ->
            when (event) {
                is PublisherEvent.TrackStarted -> trackStates[event.name] = PublishedTrackState.Active
                is PublisherEvent.TrackStopped -> trackStates[event.name] = PublishedTrackState.Stopped
                is PublisherEvent.TrackError -> {
                    trackStates[event.name] = PublishedTrackState.Stopped
                    lastError = "${event.name}: ${event.message}"
                }
            }
        }.launchIn(viewModelScope)

        for (track in tracks) {
            publisherJobs += track.state.onEach { state ->
                trackStates[track.name] = state
            }.launchIn(viewModelScope)
        }
    }
}
