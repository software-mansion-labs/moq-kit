package com.swmansion.moqpublisher

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
import com.swmansion.moqkit.MoQSession
import com.swmansion.moqkit.publish.MoQPublisher
import com.swmansion.moqkit.publish.MoQPublishedTrack
import com.swmansion.moqkit.publish.MoQPublishedTrackState
import com.swmansion.moqkit.publish.MoQPublisherEvent
import com.swmansion.moqkit.publish.MoQPublisherState
import com.swmansion.moqkit.publish.encoder.MoQAudioCodec
import com.swmansion.moqkit.publish.encoder.MoQAudioEncoderConfig
import com.swmansion.moqkit.publish.encoder.MoQVideoCodec
import com.swmansion.moqkit.publish.encoder.MoQVideoEncoderConfig
import com.swmansion.moqkit.publish.source.CameraCapture
import com.swmansion.moqkit.publish.source.CameraPosition
import com.swmansion.moqkit.publish.source.MicrophoneCapture
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

class PublisherViewModel(application: Application) : AndroidViewModel(application) {

    // Connection settings
    var relayUrl by mutableStateOf("http://192.168.92.173:4443/anon")
    var broadcastPath by mutableStateOf("live/test")

    // Source toggles
    var cameraEnabled by mutableStateOf(true)
    var micEnabled by mutableStateOf(true)
    var screenEnabled by mutableStateOf(false)
    var cameraPosition by mutableStateOf(CameraPosition.Front)

    // Codec settings
    var videoCodec by mutableStateOf(MoQVideoCodec.H264)
    var audioCodec by mutableStateOf(MoQAudioCodec.AAC)
    var videoResolution by mutableStateOf(VideoResolution.HD)
    var videoFrameRate by mutableStateOf(VideoFrameRate.FPS30)
    var audioSampleRate by mutableStateOf(48_000)

    // Observable state
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    var publisherState by mutableStateOf<MoQPublisherState>(MoQPublisherState.Idle)
    val trackStates = mutableStateMapOf<String, MoQPublishedTrackState>()
    var publishedTracks by mutableStateOf<List<MoQPublishedTrack>>(emptyList())
    var lastError by mutableStateOf<String?>(null)

    val isPublishing get() = publisherState == MoQPublisherState.Publishing
    val canPublish get() = sessionState == MoQSession.State.Idle
            && publisherState == MoQPublisherState.Idle
            && (cameraEnabled || micEnabled || screenEnabled)
    val canStop get() = isPublishing || sessionState == MoQSession.State.Connecting
            || sessionState == MoQSession.State.Connected

    val stateLabel get() = when (val s = sessionState) {
        MoQSession.State.Idle -> "idle"
        MoQSession.State.Connecting -> "connecting…"
        MoQSession.State.Connected -> "connected"
        is MoQSession.State.Error -> "error: ${s.message}"
        MoQSession.State.Closed -> "closed"
    }

    val publisherStateLabel get() = when (val s = publisherState) {
        MoQPublisherState.Idle -> "idle"
        MoQPublisherState.Publishing -> "publishing"
        MoQPublisherState.Stopped -> "stopped"
        is MoQPublisherState.Error -> "error: ${s.message}"
    }

    // Internal state
    private var session: MoQSession? = null
    private var publisher: MoQPublisher? = null
    private var camera: CameraCapture? = null
    private var microphone: MicrophoneCapture? = null
    private var screenCapture: ScreenCapture? = null
    private var screenProjectionData: Pair<Int, Intent>? = null
    private var previewSurface: Surface? = null
    private var sessionJob: Job? = null
    private var publisherJobs = mutableListOf<Job>()

    fun setPreviewSurface(surface: Surface?) {
        previewSurface = surface
        camera?.setPreviewSurface(surface)
    }

    fun startCamera(lifecycleOwner: LifecycleOwner) {
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

    fun stopCamera() {
        camera?.stop()
        camera = null
    }

    fun flipCamera() {
        cameraPosition = if (cameraPosition == CameraPosition.Front) CameraPosition.Back else CameraPosition.Front
        viewModelScope.launch {
            try {
                camera?.switchCamera()
            } catch (e: Exception) {
                lastError = "Camera flip failed: ${e.message}"
            }
        }
    }

    fun setScreenProjection(resultCode: Int, intent: Intent) {
        screenProjectionData = Pair(resultCode, intent)
    }

    fun clearScreenProjection() {
        screenProjectionData = null
    }

    fun selectAudioCodec(codec: MoQAudioCodec) {
        audioCodec = codec
        if (codec == MoQAudioCodec.OPUS && audioSampleRate != 48_000) {
            audioSampleRate = 48_000
        }
    }

    fun publish(lifecycleOwner: LifecycleOwner) {
        lastError = null
        trackStates.clear()
        publishedTracks = emptyList()

        val s = MoQSession(url = relayUrl, parentScope = viewModelScope)
        session = s

        sessionJob = s.state.onEach { sessionState = it }.launchIn(viewModelScope)

        viewModelScope.launch {
            try {
                s.connect()

                val pub = MoQPublisher()
                publisher = pub

                val videoConfig = MoQVideoEncoderConfig(
                    codec = videoCodec,
                    width = videoResolution.width,
                    height = videoResolution.height,
                    frameRate = videoFrameRate.fps,
                )
                val audioConfig = MoQAudioEncoderConfig(
                    codec = audioCodec,
                    sampleRate = audioSampleRate,
                )

                val tracks = mutableListOf<MoQPublishedTrack>()

                if (cameraEnabled) {
                    val cam = camera ?: CameraCapture(position = cameraPosition).also {
                        it.start(getApplication(), lifecycleOwner)
                        it.setPreviewSurface(previewSurface)
                        camera = it
                    }
                    tracks += pub.addVideoTrack(name = "camera", source = cam, config = videoConfig)
                    trackStates["camera"] = MoQPublishedTrackState.Idle
                }

                if (micEnabled) {
                    val mic = MicrophoneCapture(sampleRate = audioSampleRate)
                    microphone = mic
                    mic.start()
                    tracks += pub.addAudioTrack(name = "mic", source = mic, config = audioConfig)
                    trackStates["mic"] = MoQPublishedTrackState.Idle
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
                    trackStates["screen"] = MoQPublishedTrackState.Idle
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
        publisherState = MoQPublisherState.Idle
        sessionState = MoQSession.State.Idle

        viewModelScope.launch {
            pub?.stop()
            sess?.close()
        }

        cleanupSources()
    }

    override fun onCleared() {
        super.onCleared()
        stop()
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
        publisherState = MoQPublisherState.Idle
        sessionState = MoQSession.State.Idle

        viewModelScope.launch {
            try {
                pub?.stop()
            } catch (_: Exception) {}
            try {
                sess?.close()
            } catch (_: Exception) {}
        }

        cleanupSources()
    }

    private fun cleanupSources() {
        microphone?.stop()
        microphone = null
        screenCapture?.stop()
        screenCapture = null
        getApplication<Application>().stopService(
            Intent(getApplication(), ScreenCaptureService::class.java)
        )
        // Camera is kept alive for preview — only stopped on demand
    }

    private fun observePublisher(pub: MoQPublisher, tracks: List<MoQPublishedTrack>) {
        publisherJobs += pub.state.onEach { publisherState = it }.launchIn(viewModelScope)

        publisherJobs += pub.events.onEach { event ->
            when (event) {
                is MoQPublisherEvent.TrackStarted -> trackStates[event.name] = MoQPublishedTrackState.Active
                is MoQPublisherEvent.TrackStopped -> trackStates[event.name] = MoQPublishedTrackState.Stopped
                is MoQPublisherEvent.TrackError -> {
                    trackStates[event.name] = MoQPublishedTrackState.Stopped
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
