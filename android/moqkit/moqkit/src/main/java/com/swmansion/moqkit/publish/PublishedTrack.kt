package com.swmansion.moqkit.publish

import com.swmansion.moqkit.publish.encoder.AudioCodec
import com.swmansion.moqkit.publish.encoder.VideoCodec
import com.swmansion.moqkit.publish.source.CaptureTrackBinding
import com.swmansion.moqkit.publish.source.PublishControl
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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
 * @property name Local SDK label used by publisher state and events.
 * @property codecInfo Media or data kind configured for this track.
 */
open class PublishedTrack internal constructor(
    val name: String,
    val codecInfo: TrackCodecInfo,
) {
    private val _state = MutableStateFlow<PublishedTrackState>(PublishedTrackState.Idle)

    /** Current lifecycle state for this track. */
    val state: StateFlow<PublishedTrackState> = _state.asStateFlow()

    internal var stopAction: (() -> Unit)? = null
    internal var releaseAction: (() -> Unit)? = null

    /**
     * Permanently detaches this track and awaits resource teardown, including before start.
     * Capture and the broadcast remain independently owned.
     */
    suspend fun stop() = PublishControl.run { stopOwned() }

    internal fun stopOwned() {
        if (_state.value == PublishedTrackState.Stopped) return
        stopAction?.invoke()
        stopAction = null
        releaseAction?.invoke()
        releaseAction = null
        transition(PublishedTrackState.Stopped)
    }

    internal fun transition(to: PublishedTrackState) {
        if (_state.value != PublishedTrackState.Stopped) _state.value = to
    }
}

/** Audio/video publication settings; capture hardware remains explicitly controlled by the app. */
class PublishedMediaTrack internal constructor(name: String, codecInfo: TrackCodecInfo, enabled: Boolean) :
    PublishedTrack(name, codecInfo) {
    @Volatile var isEnabled: Boolean = enabled
        private set
    internal var binding: CaptureTrackBinding? = null
    internal var outputID: Any? = null

    init { if (!enabled) transition(PublishedTrackState.Disabled) }

    /** Await local encoder setup/teardown; enabling an unavailable source records intent only. */
    suspend fun setEnabled(enabled: Boolean) {
        currentCoroutineContext().ensureActive()
        PublishControl.run {
            check(state.value != PublishedTrackState.Stopped) { "Track is stopped" }
            isEnabled = enabled
            val current = binding
            if (current != null) current.setEnabled(enabled)
            else transition(if (enabled) PublishedTrackState.Idle else PublishedTrackState.Disabled)
        }
    }
}
