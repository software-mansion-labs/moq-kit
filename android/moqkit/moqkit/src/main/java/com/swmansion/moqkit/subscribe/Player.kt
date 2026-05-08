package com.swmansion.moqkit.subscribe

import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.UnsupportedCodecException
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackPipeline
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackPipelineSwitchOutcome
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackStatsTracker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

private const val TAG = "Player"

/**
 * Real-time audio/video player with fine-grained latency control.
 *
 * Uses MediaCodec (async) for decoding, AudioTrack (MODE_STREAM) for audio output,
 * and a Surface-configured MediaCodec for video output.
 *
 * ### Typical usage
 * ```kotlin
 * val player = Player(
 *     catalog = catalog,
 *     videoTrackName = catalog.videoTracks.firstOrNull()?.name,
 *     audioTrackName = catalog.audioTracks.firstOrNull()?.name,
 *     targetLatencyMs = 150,
 *     parentScope = lifecycleScope,
 * )
 * player.setSurface(surfaceView.holder.surface)
 * player.play()
 * // later:
 * player.close()
 * ```
 */
class Player(
    private val catalog: Catalog,
    videoTrackName: String? = null,
    audioTrackName: String? = null,
    targetLatencyMs: Int = 100,
    parentScope: CoroutineScope,
    volume: Float = 1f,
) : AutoCloseable {
    /**
     * Playback lifecycle events emitted by the player.
     */
    sealed class Event {
        /** A track started producing decoded output. [kind] is `"audio"` or `"video"`. */
        data class TrackPlaying(val kind: String) : Event()
        /** A track was paused via [pause]. [kind] is `"audio"` or `"video"`. */
        data class TrackPaused(val kind: String) : Event()
        /** A track's incoming data stream ended. [kind] is `"audio"` or `"video"`. */
        data class TrackStopped(val kind: String) : Event()
        /** A switched-in rendition became active. [kind] is `"audio"` or `"video"`. */
        data class TrackSwitched(val kind: String) : Event()
        /** An unrecoverable error occurred on a track. */
        data class Error(val kind: String, val message: String) : Event()
        /** All active tracks have stopped (stream ended or [stop] called). */
        object AllTracksStopped : Event()
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 8)

    val events: SharedFlow<Event> = _events

    private val broadcastOwner: BroadcastOwner
    private val statsTracker = PlaybackStatsTracker()
    private var selectedVideoTrack: VideoTrackInfo?
    private var selectedAudioTrack: AudioTrackInfo?
    private var targetLatencyMs = targetLatencyMs
    private var storedAudioVolume = volume.coerceIn(0f, 1f)
    private var surface: Surface? = null
    private var playbackPipeline: PlaybackPipeline? = null
    private var lastStats: PlaybackStats = emptyStats()
    private var playing = false
    private var closed = false

    init {
        val resolvedVideoTrack = resolveVideoTrack(videoTrackName)
        val resolvedAudioTrack = resolveAudioTrack(audioTrackName)
        check(resolvedVideoTrack != null || resolvedAudioTrack != null) {
            "at least one audio or video track is expected"
        }
        selectedVideoTrack = resolvedVideoTrack
        selectedAudioTrack = resolvedAudioTrack
        broadcastOwner = catalog.retainBroadcastOwner()
    }

    /** Current playback time in microseconds. */
    val currentTimeUs: Long
        get() = playbackPipeline?.currentTimeUs ?: 0L

    /** Current audio output volume, clamped to the 0.0-1.0 range. */
    val audioVolume: Float
        get() = storedAudioVolume

    /** Snapshot of current playback metrics. */
    val stats: PlaybackStats
        get() {
            val snapshot = playbackPipeline?.snapshotStats() ?: lastStats
            lastStats = snapshot
            return snapshot
        }

    /**
     * Set, swap, or clear the video output surface.
     */
    fun setSurface(surface: Surface?) {
        this.surface = surface
        playbackPipeline?.setSurface(surface)
    }

    /**
     * Starts audio and video playback.
     *
     * Safe to call before a surface is available. If video is selected, the video side starts
     * once [setSurface] receives a non-null surface.
     */
    fun play() {
        check(!closed) { "Player is already closed" }
        if (playing) return

        validateSelectedTracks()
        playing = true
        statsTracker.markPlayStart()
        playbackPipeline = try {
            makePlaybackPipeline()
        } catch (t: Throwable) {
            playing = false
            throw t
        }
    }

    /**
     * Switches to a different video rendition.
     *
     * Passing `null` disables video playback. If that would leave both media kinds disabled,
     * this call throws.
     */
    fun switchTrack(trackName: String?) {
        check(!closed) { "Player is already closed" }
        val newTrack = resolveVideoTrack(trackName)
        if (newTrack?.name == selectedVideoTrack?.name) return
        check(newTrack != null || selectedAudioTrack != null) {
            "at least one audio or video track is expected"
        }
        validatePlayable(newTrack)

        val wasVideoEnabled = selectedVideoTrack != null
        val pipeline = playbackPipeline
        if (pipeline != null && wasVideoEnabled && newTrack != null) {
            when (pipeline.switchVideo(newTrack)) {
                PlaybackPipelineSwitchOutcome.HANDLED -> {
                    selectedVideoTrack = newTrack
                    return
                }

                PlaybackPipelineSwitchOutcome.RESTART_REQUIRED -> Unit
            }
        }

        selectedVideoTrack = newTrack
        if (playing) restartPlaybackForSelectionChange()
    }

    /**
     * Switches to a different audio rendition.
     *
     * Passing `null` disables audio playback. If that would leave both media kinds disabled,
     * this call throws.
     */
    fun switchAudioTrack(trackName: String?) {
        check(!closed) { "Player is already closed" }
        val newTrack = resolveAudioTrack(trackName)
        if (newTrack?.name == selectedAudioTrack?.name) return
        check(selectedVideoTrack != null || newTrack != null) {
            "at least one audio or video track is expected"
        }
        validatePlayable(newTrack)

        val wasAudioEnabled = selectedAudioTrack != null
        val pipeline = playbackPipeline
        if (pipeline != null && wasAudioEnabled && newTrack != null) {
            when (pipeline.switchAudio(newTrack)) {
                PlaybackPipelineSwitchOutcome.HANDLED -> {
                    selectedAudioTrack = newTrack
                    return
                }

                PlaybackPipelineSwitchOutcome.RESTART_REQUIRED -> Unit
            }
        }

        selectedAudioTrack = newTrack
        if (playing) restartPlaybackForSelectionChange()
    }

    /**
     * Pauses playback by stopping decoders and cancelling active subscriptions.
     *
     * The player can be resumed by calling [play] again.
     */
    fun pause() {
        check(!closed) { "Player is already closed" }
        if (!playing) return

        val hadAudioTrack = selectedAudioTrack != null
        val hadVideoTrack = selectedVideoTrack != null
        Log.d(TAG, "pause")
        playing = false
        teardownPlayback(resetStats = false)

        if (hadAudioTrack) _events.tryEmit(Event.TrackPaused("audio"))
        if (hadVideoTrack) _events.tryEmit(Event.TrackPaused("video"))
    }

    /**
     * Stops playback and resets accumulated metrics.
     */
    fun stop() {
        check(!closed) { "Player is already closed" }
        if (!playing && playbackPipeline == null) {
            lastStats = emptyStats()
            return
        }

        Log.d(TAG, "stop")
        playing = false
        teardownPlayback(resetStats = true)
    }

    /**
     * Adjusts the target playback latency while the player is running.
     */
    fun updateTargetLatency(ms: Int) {
        check(!closed) { "Player is already closed" }
        targetLatencyMs = ms
        playbackPipeline?.updateTargetLatency(ms)
    }

    /**
     * Sets audio output volume for this player.
     */
    fun setVolume(volume: Float) {
        check(!closed) { "Player is already closed" }
        val clampedVolume = volume.coerceIn(0f, 1f)
        storedAudioVolume = clampedVolume
        playbackPipeline?.setVolume(clampedVolume)
    }

    /**
     * Releases the retained broadcast handle and all playback resources.
     */
    override fun close() {
        if (closed) return

        closed = true
        playing = false
        teardownPlayback(resetStats = true)
        scope.cancel()
        broadcastOwner.release()
    }

    private fun makePlaybackPipeline(): PlaybackPipeline {
        check(selectedVideoTrack != null || selectedAudioTrack != null) {
            "at least one audio or video track is expected"
        }

        return PlaybackPipeline(
            catalog = catalog,
            broadcastOwner = broadcastOwner,
            videoTrack = selectedVideoTrack,
            audioTrack = selectedAudioTrack,
            targetLatencyMs = targetLatencyMs,
            initialVolume = storedAudioVolume,
            initialSurface = surface,
            scope = scope,
            statsTracker = statsTracker,
            emitEvent = { event -> _events.tryEmit(event) },
        )
    }

    private fun restartPlaybackForSelectionChange() {
        Log.d(TAG, "Restarting playback for selection change")
        teardownPlayback(resetStats = false)
        if (playing) {
            validateSelectedTracks()
            playbackPipeline = makePlaybackPipeline()
        }
    }

    private fun teardownPlayback(resetStats: Boolean) {
        playbackPipeline?.let { pipeline ->
            lastStats = pipeline.snapshotStats()
            pipeline.stop()
        }
        playbackPipeline = null
        if (resetStats) {
            lastStats = emptyStats()
            statsTracker.reset()
        }
    }

    private fun resolveVideoTrack(trackName: String?): VideoTrackInfo? {
        if (trackName == null) return null
        return catalog.videoTracks.firstOrNull { it.name == trackName }
            ?: throw IllegalArgumentException(
                "Unknown video track '$trackName' for catalog ${catalog.path}",
            )
    }

    private fun resolveAudioTrack(trackName: String?): AudioTrackInfo? {
        if (trackName == null) return null
        return catalog.audioTracks.firstOrNull { it.name == trackName }
            ?: throw IllegalArgumentException(
                "Unknown audio track '$trackName' for catalog ${catalog.path}",
            )
    }

    private fun validateSelectedTracks() {
        validatePlayable(selectedVideoTrack)
        validatePlayable(selectedAudioTrack)
    }

    private fun validatePlayable(track: VideoTrackInfo?) {
        val reason = track?.unsupportedReason ?: return
        throw UnsupportedCodecException("Video track '${track.name}' is not playable: $reason")
    }

    private fun validatePlayable(track: AudioTrackInfo?) {
        val reason = track?.unsupportedReason ?: return
        throw UnsupportedCodecException("Audio track '${track.name}' is not playable: $reason")
    }

    private fun emptyStats(): PlaybackStats = PlaybackStats(
        audioLatencyMs = null,
        videoLatencyMs = null,
        audioStalls = null,
        videoStalls = null,
        audioBitrateKbps = null,
        videoBitrateKbps = null,
        timeToFirstAudioFrameMs = null,
        timeToFirstVideoFrameMs = null,
        videoFps = null,
        audioFramesDropped = null,
        videoFramesDropped = null,
        audioRingBufferMs = null,
        videoJitterBufferMs = null,
        videoDecodeStats = null,
        audioArrival = null,
        videoArrival = null,
    )
}
