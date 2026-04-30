package com.swmansion.moqkit.publish

import android.util.Log
import com.swmansion.moqkit.publish.encoder.AudioEncoder
import com.swmansion.moqkit.publish.encoder.AudioEncoderConfig
import com.swmansion.moqkit.publish.encoder.VideoEncoder
import com.swmansion.moqkit.publish.encoder.VideoEncoderConfig
import com.swmansion.moqkit.publish.source.AudioFrameSource
import com.swmansion.moqkit.publish.source.VideoFrameSource
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import uniffi.moq.MoqBroadcastProducer
import uniffi.moq.MoqMediaProducer
import uniffi.moq.MoqTrackProducer

private const val TAG = "Publisher"

class Publisher {
    private val _state = MutableStateFlow<PublisherState>(PublisherState.Idle)
    val state: StateFlow<PublisherState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<PublisherEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<PublisherEvent> = _events

    internal val broadcast = MoqBroadcastProducer()
    internal val clock = Clock()

    // Descriptors registered before start()
    private val videoDescriptors = mutableListOf<VideoTrackDescriptor>()
    private val audioDescriptors = mutableListOf<AudioTrackDescriptor>()
    private val dataDescriptors = mutableListOf<DataTrackDescriptor>()

    // Active runtime state
    private val activeVideoTracks = mutableMapOf<String, ActiveVideoTrack>()
    private val activeAudioTracks = mutableMapOf<String, ActiveAudioTrack>()
    private val activeDataTracks = mutableMapOf<String, ActiveDataTrack>()

    fun addVideoTrack(
        name: String = "video",
        source: VideoFrameSource,
        config: VideoEncoderConfig = VideoEncoderConfig(),
    ): PublishedTrack {
        require(videoDescriptors.none { it.track.name == name }) { "Video track '$name' already added" }
        val track = PublishedTrack(
            name = name,
            codecInfo = TrackCodecInfo.Video(config.codec, config.width, config.height, config.frameRate),
        )
        videoDescriptors.add(VideoTrackDescriptor(track, source, config))
        return track
    }

    fun addAudioTrack(
        name: String = "audio",
        source: AudioFrameSource,
        config: AudioEncoderConfig = AudioEncoderConfig(),
    ): PublishedTrack {
        require(audioDescriptors.none { it.track.name == name }) { "Audio track '$name' already added" }
        val track = PublishedTrack(
            name = name,
            codecInfo = TrackCodecInfo.Audio(config.codec, config.sampleRate),
        )
        audioDescriptors.add(AudioTrackDescriptor(track, source, config))
        return track
    }

    fun addDataTrack(
        name: String = "data",
        emitter: DataTrackEmitter,
    ): PublishedTrack {
        require(dataDescriptors.none { it.track.name == name }) { "Data track '$name' already added" }
        val track = PublishedTrack(name = name, codecInfo = TrackCodecInfo.Data)
        dataDescriptors.add(DataTrackDescriptor(track, emitter))
        return track
    }

    fun start() {
        check(_state.value == PublisherState.Idle) { "Publisher already started" }
        Log.d(TAG, "Starting publisher: ${videoDescriptors.size} video, ${audioDescriptors.size} audio, ${dataDescriptors.size} data tracks")

        for (desc in videoDescriptors) startVideoTrack(desc)
        for (desc in audioDescriptors) startAudioTrack(desc)
        for (desc in dataDescriptors) startDataTrack(desc)

        _state.value = PublisherState.Publishing
        checkAllTracksStopped()
    }

    fun stop() {
        val current = _state.value
        if (current == PublisherState.Stopped || current is PublisherState.Error) return
        Log.d(TAG, "Stopping publisher")

        for ((_, active) in activeVideoTracks) tearDownVideoTrack(active)
        activeVideoTracks.clear()

        for ((_, active) in activeAudioTracks) tearDownAudioTrack(active)
        activeAudioTracks.clear()

        for ((_, active) in activeDataTracks) tearDownDataTrack(active)
        activeDataTracks.clear()

        try { broadcast.finish() } catch (_: Exception) {}
        clock.reset()

        for (desc in videoDescriptors) emitTrackStopped(desc.track)
        for (desc in audioDescriptors) emitTrackStopped(desc.track)
        for (desc in dataDescriptors) emitTrackStopped(desc.track)

        _state.value = PublisherState.Stopped
    }

    // MARK: - Video

    private fun startVideoTrack(desc: VideoTrackDescriptor) {
        val active = ActiveVideoTrack()
        val encoder = VideoEncoder(desc.config)
        active.encoder = encoder
        active.source = desc.source
        val trackHandle = desc.track
        val clock = clock
        val broadcast = broadcast

        encoder.start { frame ->
            if (active.mediaProducer == null) {
                val initData = frame.initData ?: return@start
                try {
                    active.mediaProducer = broadcast.publishMedia(desc.config.format, initData)
                    Log.d(TAG, "Video track '${trackHandle.name}' active")
                    trackHandle.transition(PublishedTrackState.Active)
                    _events.tryEmit(PublisherEvent.TrackStarted(trackHandle.name))
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to create video producer: $e")
                    trackHandle.transition(PublishedTrackState.Stopped)
                    _events.tryEmit(PublisherEvent.TrackError(trackHandle.name, e.message ?: "unknown"))
                    return@start
                }
            }
            try {
                active.mediaProducer?.writeFrame(frame.data, clock.timestampUs(frame.timestampUs).toULong())
            } catch (e: Exception) {
                Log.w(TAG, "writeFrame error: $e")
            }
        }

        val encoderSurface = encoder.encoderInputSurface
        if (encoderSurface != null) {
            desc.source.attachEncoderSurface(encoderSurface)
        }

        trackHandle.transition(PublishedTrackState.Starting)

        trackHandle.stopAction = {
            tearDownVideoTrack(active)
            activeVideoTracks.remove(trackHandle.name)
            trackHandle.transition(PublishedTrackState.Stopped)
            _events.tryEmit(PublisherEvent.TrackStopped(trackHandle.name))
            checkAllTracksStopped()
        }

        activeVideoTracks[desc.track.name] = active
    }

    private fun tearDownVideoTrack(active: ActiveVideoTrack) {
        active.source?.detachEncoderSurface()
        active.encoder?.stop()
        try { active.mediaProducer?.finish() } catch (_: Exception) {}
    }

    // MARK: - Audio

    private fun startAudioTrack(desc: AudioTrackDescriptor) {
        val active = ActiveAudioTrack()
        val encoder = AudioEncoder(desc.config)
        active.encoder = encoder
        active.source = desc.source
        val trackHandle = desc.track
        val clock = clock
        val broadcast = broadcast

        encoder.start(desc.source) { frame ->
            if (active.mediaProducer == null) {
                val initData = frame.initData ?: return@start
                try {
                    active.mediaProducer = broadcast.publishMedia(desc.config.format, initData)
                    Log.d(TAG, "Audio track '${trackHandle.name}' active")
                    trackHandle.transition(PublishedTrackState.Active)
                    _events.tryEmit(PublisherEvent.TrackStarted(trackHandle.name))
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to create audio producer: $e")
                    trackHandle.transition(PublishedTrackState.Stopped)
                    _events.tryEmit(PublisherEvent.TrackError(trackHandle.name, e.message ?: "unknown"))
                    return@start
                }
            }
            try {
                active.mediaProducer?.writeFrame(frame.data, clock.timestampUs(frame.timestampUs).toULong())
            } catch (e: Exception) {
                Log.w(TAG, "writeFrame error: $e")
            }
        }

        trackHandle.transition(PublishedTrackState.Starting)

        trackHandle.stopAction = {
            tearDownAudioTrack(active)
            activeAudioTracks.remove(trackHandle.name)
            trackHandle.transition(PublishedTrackState.Stopped)
            _events.tryEmit(PublisherEvent.TrackStopped(trackHandle.name))
            checkAllTracksStopped()
        }

        activeAudioTracks[desc.track.name] = active
    }

    private fun tearDownAudioTrack(active: ActiveAudioTrack) {
        active.source?.onPcmData = null
        active.encoder?.stop()
        try { active.mediaProducer?.finish() } catch (_: Exception) {}
    }

    // MARK: - Data

    private fun startDataTrack(desc: DataTrackDescriptor) {
        val producer = broadcast.publishTrack(desc.track.name)
        val active = ActiveDataTrack(desc.emitter, producer)
        desc.emitter.attach(producer)

        val trackHandle = desc.track
        trackHandle.stopAction = {
            tearDownDataTrack(active)
            activeDataTracks.remove(trackHandle.name)
            trackHandle.transition(PublishedTrackState.Stopped)
            _events.tryEmit(PublisherEvent.TrackStopped(trackHandle.name))
            checkAllTracksStopped()
        }

        activeDataTracks[desc.track.name] = active
        trackHandle.transition(PublishedTrackState.Active)
        _events.tryEmit(PublisherEvent.TrackStarted(trackHandle.name))
    }

    private fun tearDownDataTrack(active: ActiveDataTrack) {
        active.emitter?.detach()
        try { active.producer?.finish() } catch (_: Exception) {}
        try { active.producer?.close() } catch (_: Exception) {}
    }

    // MARK: - Lifecycle

    private fun checkAllTracksStopped() {
        if (activeVideoTracks.isEmpty() && activeAudioTracks.isEmpty() && activeDataTracks.isEmpty()
            && _state.value == PublisherState.Publishing
        ) {
            _state.value = PublisherState.Stopped
        }
    }

    private fun emitTrackStopped(track: PublishedTrack) {
        track.transition(PublishedTrackState.Stopped)
        _events.tryEmit(PublisherEvent.TrackStopped(track.name))
    }

    // MARK: - Internal descriptor / runtime types

    private data class VideoTrackDescriptor(
        val track: PublishedTrack,
        val source: VideoFrameSource,
        val config: VideoEncoderConfig,
    )

    private data class AudioTrackDescriptor(
        val track: PublishedTrack,
        val source: AudioFrameSource,
        val config: AudioEncoderConfig,
    )

    private data class DataTrackDescriptor(
        val track: PublishedTrack,
        val emitter: DataTrackEmitter,
    )

    private class ActiveVideoTrack {
        var source: VideoFrameSource? = null
        var encoder: VideoEncoder? = null
        var mediaProducer: MoqMediaProducer? = null
    }

    private class ActiveAudioTrack {
        var source: AudioFrameSource? = null
        var encoder: AudioEncoder? = null
        var mediaProducer: MoqMediaProducer? = null
    }

    private data class ActiveDataTrack(
        val emitter: DataTrackEmitter?,
        val producer: MoqTrackProducer?,
    )
}
