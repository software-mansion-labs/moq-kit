package com.swmansion.moqkit.publish

import com.swmansion.moqkit.publish.encoder.MoQAudioCodec
import com.swmansion.moqkit.publish.encoder.MoQVideoCodec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class MoQTrackCodecInfo {
    data class Video(
        val codec: MoQVideoCodec,
        val width: Int,
        val height: Int,
        val frameRate: Int,
    ) : MoQTrackCodecInfo()

    data class Audio(val codec: MoQAudioCodec, val sampleRate: Int) : MoQTrackCodecInfo()
    object Data : MoQTrackCodecInfo()
}

class MoQPublishedTrack internal constructor(
    val name: String,
    val codecInfo: MoQTrackCodecInfo,
) {
    private val _state = MutableStateFlow(MoQPublishedTrackState.Idle)
    val state: StateFlow<MoQPublishedTrackState> = _state.asStateFlow()

    internal var stopAction: (() -> Unit)? = null

    fun stop() {
        if (_state.value == MoQPublishedTrackState.Stopped) return
        stopAction?.invoke()
    }

    internal fun transition(to: MoQPublishedTrackState) {
        _state.value = to
    }
}
