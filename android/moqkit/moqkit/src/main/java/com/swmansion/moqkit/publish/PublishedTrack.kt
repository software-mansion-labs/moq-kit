package com.swmansion.moqkit.publish

import com.swmansion.moqkit.publish.encoder.AudioCodec
import com.swmansion.moqkit.publish.encoder.VideoCodec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class TrackCodecInfo {
    data class Video(
        val codec: VideoCodec,
        val width: Int,
        val height: Int,
        val frameRate: Int,
    ) : TrackCodecInfo()

    data class Audio(val codec: AudioCodec, val sampleRate: Int) : TrackCodecInfo()
    object Data : TrackCodecInfo()
}

class PublishedTrack internal constructor(
    val name: String,
    val codecInfo: TrackCodecInfo,
) {
    private val _state = MutableStateFlow(PublishedTrackState.Idle)
    val state: StateFlow<PublishedTrackState> = _state.asStateFlow()

    internal var stopAction: (() -> Unit)? = null

    fun stop() {
        if (_state.value == PublishedTrackState.Stopped) return
        stopAction?.invoke()
    }

    internal fun transition(to: PublishedTrackState) {
        _state.value = to
    }
}
