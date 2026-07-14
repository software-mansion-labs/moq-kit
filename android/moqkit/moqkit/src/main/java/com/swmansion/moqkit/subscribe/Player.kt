package com.swmansion.moqkit.subscribe

import android.util.Log
import android.view.Surface
import com.swmansion.moqkit.UnsupportedCodecException
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackPipeline
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackPipelineSwitchOutcome
import com.swmansion.moqkit.subscribe.internal.playback.PlayerEventHub
import com.swmansion.moqkit.subscribe.internal.playback.PlaybackStatsTracker
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineBus
import com.swmansion.moqkit.subscribe.internal.pipeline.PipelineStallCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import java.time.Duration

private const val TAG = "Player"

/**
 * Plays audio and video tracks from a broadcast catalog.
 *
 * Choose track names from [Catalog.playableVideoTracks] and [Catalog.playableAudioTracks],
 * set a video [Surface] if video is selected, and call [play]. The player keeps the
 * underlying broadcast open until [close] is called.
 *
 * Internally this uses Android's MediaCodec and AudioTrack APIs.
 *
 * ### Typical usage
 * ```kotlin
 * val player = Player(
 *     catalog = catalog,
 *     videoTrackName = catalog.videoTracks.firstOrNull()?.name,
 *     audioTrackName = catalog.audioTracks.firstOrNull()?.name,
 *     targetBuffering = Duration.ofMillis(150),
 *     parentScope = lifecycleScope,
 * )
 * player.setSurface(surfaceView.holder.surface)
 * player.play()
 * // later:
 * player.close()
 * ```
 *
 * @param catalog Catalog emitted by [Broadcast.catalogs].
 * @param videoTrackName Video track name to play, or `null` for audio-only playback.
 * @param audioTrackName Audio track name to play, or `null` for video-only playback.
 * @param targetBuffering Desired live playback buffering depth.
 * @param parentScope Coroutine scope that owns playback work.
 * @param volume Initial audio volume, clamped to the 0.0-1.0 range.
 * @throws IllegalArgumentException if a selected track name does not exist.
 * @throws IllegalStateException if both track names are `null`.
 */
class Player(
    private val catalog: Catalog,
    videoTrackName: String? = null,
    audioTrackName: String? = null,
    targetBuffering: Duration = Duration.ofMillis(100),
    parentScope: CoroutineScope,
    volume: Float = 1f,
) : AutoCloseable {
    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())
    private val eventHub = PlayerEventHub()
    private val pipelineBus = PipelineBus()
    private val stallCoordinator = PipelineStallCoordinator(pipelineBus, scope)
    private val statsTracker = PlaybackStatsTracker(events = eventHub)
    private val pipelineStatsObservation = pipelineBus.observe(statsTracker::onPipelineEvent)
    private val mutableStatsUpdates = MutableSharedFlow<PlaybackStats>(extraBufferCapacity = 8)

    /**
     * Playback lifecycle events.
     *
     * Events are not replayed. Collect before [play] if startup events are needed.
     */
    val events: SharedFlow<PlayerEvent> = eventHub.events

    /**
     * Pushed playback stats snapshots sampled while playback is active.
     */
    val statsUpdates: SharedFlow<PlaybackStats> = mutableStatsUpdates.asSharedFlow()

    /**
     * Detailed, non-replayed media-pipeline diagnostics.
     *
     * Lifecycle events remain available through [events]; this stream carries per-stage
     * admission, drop, recovery, scheduling, and stall-attribution facts.
     */
    fun diagnostics(): Flow<PipelineEvent> = pipelineBus.events

    private val broadcastOwner: BroadcastOwner
    private var selectedVideoTrack: VideoTrackInfo?
    private var selectedAudioTrack: AudioTrackInfo?
    private var targetBuffering = targetBuffering
    private var storedAudioVolume = volume.coerceIn(0f, 1f)
    private var surface: Surface? = null
    private var playbackPipeline: PlaybackPipeline? = null
    private var lastStats: PlaybackStats = PlaybackStats.Empty
    private var statsSamplingJob: Job? = null
    private var playing = false
    private var isPaused = false
    private var hasStartedPlaybackSession = false
    private var closed = false
    private var destroyed = false

    init {
        val resolvedVideoTrack = resolveVideoTrack(videoTrackName)
        val resolvedAudioTrack = resolveAudioTrack(audioTrackName)
        check(resolvedVideoTrack != null || resolvedAudioTrack != null) {
            "at least one audio or video track is expected"
        }
        selectedVideoTrack = resolvedVideoTrack
        selectedAudioTrack = resolvedAudioTrack
        broadcastOwner = catalog.retainBroadcastOwner()
        eventHub.emit(PlayerEventType.PlayerInit(sessionEvent))
        emitSelectedTrackSelect()
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
     * Sets, swaps, or clears the video output surface.
     *
     * It is safe to call this before [play]. If video playback is selected and the surface
     * is `null`, audio can start while video waits for a surface.
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
     *
     * @throws UnsupportedCodecException if a selected track cannot be decoded on this device.
     */
    fun play() {
        check(!closed) { "Player is already closed" }
        if (playing) return

        validateSelectedTracks()
        eventHub.emit(PlayerEventType.PlaybackRequest(sessionEvent))
        statsTracker.beginSession(
            rebufferKind = if (selectedAudioTrack != null) {
                com.swmansion.moqkit.subscribe.internal.playback.MediaFrameKind.AUDIO
            } else {
                com.swmansion.moqkit.subscribe.internal.playback.MediaFrameKind.VIDEO
            },
        )
        playing = true
        hasStartedPlaybackSession = true
        val shouldEmitResume = isPaused
        stallCoordinator.start()
        playbackPipeline = try {
            makePlaybackPipeline()
        } catch (t: Throwable) {
            stallCoordinator.stop()
            playing = false
            hasStartedPlaybackSession = false
            throw t
        }
        if (shouldEmitResume) {
            eventHub.emit(PlayerEventType.PlaybackResume(sessionEvent))
        }
        isPaused = false
        startStatsSampling()
        publishStatsSample()
    }

    /**
     * Switches to a different video rendition.
     *
     * Passing `null` disables video playback. If that would leave both media kinds disabled,
     * this call throws.
     *
     * @throws IllegalArgumentException if [trackName] is unknown.
     * @throws IllegalStateException if disabling video would leave no track selected.
     * @throws UnsupportedCodecException if the selected track cannot be decoded.
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
                    emitTrackSelect(PlayerTrackKind.VIDEO, newTrack.name)
                    return
                }

                PlaybackPipelineSwitchOutcome.RESTART_REQUIRED -> Unit
            }
        }

        selectedVideoTrack = newTrack
        emitTrackSelect(PlayerTrackKind.VIDEO, newTrack?.name)
        if (playing) restartPlaybackForSelectionChange()
    }

    /**
     * Switches to a different audio rendition.
     *
     * Passing `null` disables audio playback. If that would leave both media kinds disabled,
     * this call throws.
     *
     * @throws IllegalArgumentException if [trackName] is unknown.
     * @throws IllegalStateException if disabling audio would leave no track selected.
     * @throws UnsupportedCodecException if the selected track cannot be decoded.
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
                    emitTrackSelect(PlayerTrackKind.AUDIO, newTrack.name)
                    return
                }

                PlaybackPipelineSwitchOutcome.RESTART_REQUIRED -> Unit
            }
        }

        selectedAudioTrack = newTrack
        emitTrackSelect(PlayerTrackKind.AUDIO, newTrack?.name)
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

        Log.d(TAG, "pause")
        playing = false
        teardownPlayback(permanent = false, reason = "pause()")
        eventHub.emit(PlayerEventType.PlaybackPause(sessionEvent))
        isPaused = true
    }

    /**
     * Stops playback, closes active subscriptions, and resets accumulated metrics.
     */
    fun stopAll(reason: String = "caller requested stopAll") {
        check(!closed) { "Player is already closed" }

        Log.d(TAG, "stopAll reason=$reason")
        playing = false
        teardownPlayback(permanent = true, reason = reason)
    }

    /**
     * Adjusts the target playback buffering depth while the player is running.
     *
     * Lower values reduce delay but can increase stalls on unstable networks.
     */
    fun updateTargetLatency(latency: Duration) {
        check(!closed) { "Player is already closed" }
        targetBuffering = latency
        playbackPipeline?.updateTargetLatency(latency)
    }

    /**
     * Sets audio output volume for this player.
     *
     * Values outside the 0.0-1.0 range are clamped.
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
        teardownPlayback(permanent = true, reason = "close()")
        emitPlayerDestroy()
        pipelineStatsObservation.close()
        stallCoordinator.close()
        scope.cancel()
        broadcastOwner.release()
    }

    private fun makePlaybackPipeline(): PlaybackPipeline {
        check(selectedVideoTrack != null || selectedAudioTrack != null) {
            "at least one audio or video track is expected"
        }

        return PlaybackPipeline(
            broadcastOwner = broadcastOwner,
            videoTrack = selectedVideoTrack,
            audioTrack = selectedAudioTrack,
            targetBuffering = targetBuffering,
            initialVolume = storedAudioVolume,
            initialSurface = surface,
            scope = scope,
            statsTracker = statsTracker,
            pipelineBus = pipelineBus,
        )
    }

    private fun restartPlaybackForSelectionChange() {
        Log.d(TAG, "Restarting playback for selection change")
        teardownPlayback(permanent = false, reason = "track selection changed")
        if (playing) {
            validateSelectedTracks()
            eventHub.emit(PlayerEventType.PlaybackRequest(sessionEvent))
            statsTracker.beginSession(
                rebufferKind = if (selectedAudioTrack != null) {
                    com.swmansion.moqkit.subscribe.internal.playback.MediaFrameKind.AUDIO
                } else {
                    com.swmansion.moqkit.subscribe.internal.playback.MediaFrameKind.VIDEO
                },
            )
            stallCoordinator.start()
            playbackPipeline = makePlaybackPipeline()
            startStatsSampling()
            publishStatsSample()
        }
    }

    private fun teardownPlayback(permanent: Boolean, reason: String) {
        playbackPipeline?.let { pipeline ->
            lastStats = pipeline.snapshotStats()
            pipeline.stop()
        }
        playbackPipeline = null
        stallCoordinator.stop()
        stopStatsSampling()
        statsTracker.closeOutInFlightStalls()
        if (permanent) {
            if (hasStartedPlaybackSession) {
                statsTracker.emitPlaybackEnd(reason)
            }
            lastStats = PlaybackStats.Empty
            statsTracker.reset()
            hasStartedPlaybackSession = false
            isPaused = false
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

    private fun startStatsSampling() {
        statsSamplingJob?.cancel()
        statsSamplingJob = scope.launch {
            while (true) {
                delay(1_000L)
                publishStatsSample()
            }
        }
    }

    private fun stopStatsSampling() {
        statsSamplingJob?.cancel()
        statsSamplingJob = null
    }

    private fun publishStatsSample() {
        val pipeline = playbackPipeline ?: return
        val snapshot = pipeline.snapshotStats()
        lastStats = snapshot
        mutableStatsUpdates.tryEmit(snapshot)
    }

    private val sessionEvent: PlayerSessionEvent
        get() = PlayerSessionEvent(
            catalogPath = catalog.path,
            targetBuffering = targetBuffering,
            videoTrackName = selectedVideoTrack?.name,
            audioTrackName = selectedAudioTrack?.name,
        )

    private fun emitSelectedTrackSelect() {
        selectedVideoTrack?.let { emitTrackSelect(PlayerTrackKind.VIDEO, it.name) }
        selectedAudioTrack?.let { emitTrackSelect(PlayerTrackKind.AUDIO, it.name) }
    }

    private fun emitTrackSelect(kind: PlayerTrackKind, trackName: String?) {
        eventHub.emit(
            PlayerEventType.TrackSelect(
                PlayerTrackSelectionEvent(
                    kind = kind,
                    trackName = trackName,
                ),
            ),
        )
    }

    private fun emitPlayerDestroy() {
        if (destroyed) return
        destroyed = true
        eventHub.emit(PlayerEventType.PlayerDestroy)
    }
}
