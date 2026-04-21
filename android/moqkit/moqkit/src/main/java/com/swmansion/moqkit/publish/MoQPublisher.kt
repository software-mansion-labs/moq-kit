package com.swmansion.moqkit.publish

import android.util.Log
import com.swmansion.moqkit.publish.encoder.MoQAudioEncoder
import com.swmansion.moqkit.publish.encoder.MoQAudioEncoderConfig
import com.swmansion.moqkit.publish.encoder.MoQVideoEncoder
import com.swmansion.moqkit.publish.encoder.MoQVideoEncoderConfig
import com.swmansion.moqkit.publish.source.AudioFrameSource
import com.swmansion.moqkit.publish.source.VideoFrameSource
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import uniffi.moq.MoqBroadcastProducer
import uniffi.moq.MoqMediaProducer

private const val TAG = "MoQPublisher"

class MoQPublisher {
    private val _state = MutableStateFlow<MoQPublisherState>(MoQPublisherState.Idle)
    val state: StateFlow<MoQPublisherState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<MoQPublisherEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<MoQPublisherEvent> = _events

    internal val broadcast = MoqBroadcastProducer()
    internal val clock = MoQClock()

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
        config: MoQVideoEncoderConfig = MoQVideoEncoderConfig(),
    ): MoQPublishedTrack {
        require(videoDescriptors.none { it.track.name == name }) { "Video track '$name' already added" }
        val track = MoQPublishedTrack(
            name = name,
            codecInfo = MoQTrackCodecInfo.Video(config.codec, config.width, config.height, config.frameRate),
        )
        videoDescriptors.add(VideoTrackDescriptor(track, source, config))
        return track
    }

    fun addAudioTrack(
        name: String = "audio",
        source: AudioFrameSource,
        config: MoQAudioEncoderConfig = MoQAudioEncoderConfig(),
    ): MoQPublishedTrack {
        require(audioDescriptors.none { it.track.name == name }) { "Audio track '$name' already added" }
        val track = MoQPublishedTrack(
            name = name,
            codecInfo = MoQTrackCodecInfo.Audio(config.codec, config.sampleRate),
        )
        audioDescriptors.add(AudioTrackDescriptor(track, source, config))
        return track
    }

    fun addDataTrack(
        name: String = "data",
        emitter: DataTrackEmitter,
    ): MoQPublishedTrack {
        require(dataDescriptors.none { it.track.name == name }) { "Data track '$name' already added" }
        val track = MoQPublishedTrack(name = name, codecInfo = MoQTrackCodecInfo.Data)
        dataDescriptors.add(DataTrackDescriptor(track, emitter))
        return track
    }

    fun start() {
        check(_state.value == MoQPublisherState.Idle) { "Publisher already started" }
        Log.d(TAG, "Starting publisher: ${videoDescriptors.size} video, ${audioDescriptors.size} audio, ${dataDescriptors.size} data tracks")

        for (desc in videoDescriptors) startVideoTrack(desc)
        for (desc in audioDescriptors) startAudioTrack(desc)
        for (desc in dataDescriptors) startDataTrack(desc)

        _state.value = MoQPublisherState.Publishing
        checkAllTracksStopped()
    }

    fun stop() {
        val current = _state.value
        if (current == MoQPublisherState.Stopped || current is MoQPublisherState.Error) return
        Log.d(TAG, "Stopping publisher")

        for ((_, active) in activeVideoTracks) tearDownVideoTrack(active)
        activeVideoTracks.clear()

        for ((_, active) in activeAudioTracks) tearDownAudioTrack(active)
        activeAudioTracks.clear()

        for ((_, active) in activeDataTracks) { active.emitter?.detach() }
        activeDataTracks.clear()

        try { broadcast.finish() } catch (_: Exception) {}
        clock.reset()

        for (desc in videoDescriptors) emitTrackStopped(desc.track)
        for (desc in audioDescriptors) emitTrackStopped(desc.track)
        for (desc in dataDescriptors) emitTrackStopped(desc.track)

        _state.value = MoQPublisherState.Stopped
    }

    // MARK: - Video

    private fun startVideoTrack(desc: VideoTrackDescriptor) {
        val active = ActiveVideoTrack()
        val encoder = MoQVideoEncoder(desc.config)
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
                    trackHandle.transition(MoQPublishedTrackState.Active)
                    _events.tryEmit(MoQPublisherEvent.TrackStarted(trackHandle.name))
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to create video producer: $e")
                    trackHandle.transition(MoQPublishedTrackState.Stopped)
                    _events.tryEmit(MoQPublisherEvent.TrackError(trackHandle.name, e.message ?: "unknown"))
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

        trackHandle.transition(MoQPublishedTrackState.Starting)

        trackHandle.stopAction = {
            tearDownVideoTrack(active)
            activeVideoTracks.remove(trackHandle.name)
            trackHandle.transition(MoQPublishedTrackState.Stopped)
            _events.tryEmit(MoQPublisherEvent.TrackStopped(trackHandle.name))
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
        val encoder = MoQAudioEncoder(desc.config)
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
                    trackHandle.transition(MoQPublishedTrackState.Active)
                    _events.tryEmit(MoQPublisherEvent.TrackStarted(trackHandle.name))
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to create audio producer: $e")
                    trackHandle.transition(MoQPublishedTrackState.Stopped)
                    _events.tryEmit(MoQPublisherEvent.TrackError(trackHandle.name, e.message ?: "unknown"))
                    return@start
                }
            }
            try {
                active.mediaProducer?.writeFrame(frame.data, clock.timestampUs(frame.timestampUs).toULong())
            } catch (e: Exception) {
                Log.w(TAG, "writeFrame error: $e")
            }
        }

        trackHandle.transition(MoQPublishedTrackState.Starting)

        trackHandle.stopAction = {
            tearDownAudioTrack(active)
            activeAudioTracks.remove(trackHandle.name)
            trackHandle.transition(MoQPublishedTrackState.Stopped)
            _events.tryEmit(MoQPublisherEvent.TrackStopped(trackHandle.name))
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
        // Requires MoqTrackProducer from Android bindings. Run `mise run build-android`
        // to regenerate. After rebuild, replace this body with:
        //   val producer = broadcast.publishTrack(desc.track.name)
        //   desc.emitter.attachWriter { data -> producer.writeFrame(data) }
        //   desc.track.stopAction = { desc.emitter.detach(); producer.finish(); ... }
        //   desc.track.transition(MoQPublishedTrackState.Active)
        Log.w(TAG, "Data track '${desc.track.name}': skipped (requires binding rebuild)")
        desc.track.transition(MoQPublishedTrackState.Stopped)
        _events.tryEmit(MoQPublisherEvent.TrackError(desc.track.name, "Requires binding rebuild: run `mise run build-android`"))
    }

    // MARK: - Lifecycle

    private fun checkAllTracksStopped() {
        if (activeVideoTracks.isEmpty() && activeAudioTracks.isEmpty() && activeDataTracks.isEmpty()
            && _state.value == MoQPublisherState.Publishing
        ) {
            _state.value = MoQPublisherState.Stopped
        }
    }

    private fun emitTrackStopped(track: MoQPublishedTrack) {
        track.transition(MoQPublishedTrackState.Stopped)
        _events.tryEmit(MoQPublisherEvent.TrackStopped(track.name))
    }

    // MARK: - Internal descriptor / runtime types

    private data class VideoTrackDescriptor(
        val track: MoQPublishedTrack,
        val source: VideoFrameSource,
        val config: MoQVideoEncoderConfig,
    )

    private data class AudioTrackDescriptor(
        val track: MoQPublishedTrack,
        val source: AudioFrameSource,
        val config: MoQAudioEncoderConfig,
    )

    private data class DataTrackDescriptor(
        val track: MoQPublishedTrack,
        val emitter: DataTrackEmitter,
    )

    private class ActiveVideoTrack {
        var source: VideoFrameSource? = null
        var encoder: MoQVideoEncoder? = null
        var mediaProducer: MoqMediaProducer? = null
    }

    private class ActiveAudioTrack {
        var source: AudioFrameSource? = null
        var encoder: MoQAudioEncoder? = null
        var mediaProducer: MoqMediaProducer? = null
    }

    private data class ActiveDataTrack(val emitter: DataTrackEmitter?)
}
