package com.swmansion.moqkit.publish

import com.swmansion.moqkit.publish.encoder.AudioCodec
import com.swmansion.moqkit.publish.encoder.VideoCodec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Codec information for a track configured on a [Publisher].
 */
sealed class TrackCodecInfo {
    /** Video track settings selected before publishing starts. */
    data class Video(
        val codec: VideoCodec,
        val width: Int,
        val height: Int,
        val frameRate: Int,
    ) : TrackCodecInfo()

    /** Audio track settings selected before publishing starts. */
    data class Audio(val codec: AudioCodec, val sampleRate: Int) : TrackCodecInfo()

    /** Raw binary data track. */
    object Data : TrackCodecInfo()
}

/**
 * Handle returned when a track is added to a [Publisher].
 *
 * Use [state] to update UI for a specific track, or call [stop] to stop just this track
 * while leaving other publisher tracks running.
 *
 * @property name Track name announced in the broadcast.
 * @property codecInfo Media or data kind configured for this track.
 */
class PublishedTrack internal constructor(
    val name: String,
    val codecInfo: TrackCodecInfo,
) {
    private val _state = MutableStateFlow(PublishedTrackState.Idle)

    /** Current lifecycle state for this track. */
    val state: StateFlow<PublishedTrackState> = _state.asStateFlow()

    internal var stopAction: (() -> Unit)? = null

    /**
     * Stops this track if it is active.
     *
     * Calling this before [Publisher.start] has no effect because no native producer has
     * been attached yet.
     */
    fun stop() {
        if (_state.value == PublishedTrackState.Stopped) return
        stopAction?.invoke()
    }

    internal fun transition(to: PublishedTrackState) {
        _state.value = to
    }
}
