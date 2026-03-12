@file:OptIn(UnstableApi::class) package com.swmansion.moqkit

import android.content.Context
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

class MoQPlayer(
    private val context: Context,
    private val tracks: List<MoQTrackInfo>,
    private val maxLatencyMs: ULong = 1000u,
    parentScope: CoroutineScope,
) {
    companion object {
        private const val TAG = "MoQPlayer"
    }

    sealed class Event {
        object Playing : Event()
        object Paused : Event()
        data class Error(val code: Int, val message: String) : Event()
        object Stopped : Event()
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 8)
    val events: SharedFlow<Event> = _events

    var exoPlayer: ExoPlayer? = null
        private set

    fun start(): ExoPlayer {
        Log.d(TAG, "start: ${tracks.size} tracks (maxLatencyMs=$maxLatencyMs)")
        releasePlayer()

        val videoInfo = tracks.filterIsInstance<MoQVideoTrackInfo>().firstOrNull()
        val audioInfo = tracks.filterIsInstance<MoQAudioTrackInfo>().firstOrNull()
        Log.d(TAG, "Selected video='${videoInfo?.name}' audio='${audioInfo?.name}'")

        val videoFormat = videoInfo?.let { MediaFactory.makeVideoFormatMedia3(it.config) }
        val audioFormat = audioInfo?.let { MediaFactory.makeAudioFormatMedia3(it.config) }
        Log.d(TAG, "Formats: video=${videoFormat?.sampleMimeType} ${videoFormat?.width}x${videoFormat?.height}, audio=${audioFormat?.sampleMimeType} ${audioFormat?.sampleRate}Hz")

        val videoFlow = videoInfo?.let {
            subscribeTrack(it.broadcast, it.name, maxLatencyMs)
        }
        val audioFlow = audioInfo?.let {
            subscribeTrack(it.broadcast, it.name, maxLatencyMs)
        }

        val source = MoQMediaSource(videoFormat, audioFormat, videoFlow, audioFlow, scope)
        val newPlayer = ExoPlayer.Builder(context).build()
        Log.d(TAG, "ExoPlayer created")

        newPlayer.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "Player error: ${error.errorCodeName} cause=${error.cause}", error)
                _events.tryEmit(Event.Error(error.errorCode, error.errorCodeName))
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                val stateName = when (playbackState) {
                    Player.STATE_IDLE -> "IDLE"
                    Player.STATE_BUFFERING -> "BUFFERING"
                    Player.STATE_READY -> "READY"
                    Player.STATE_ENDED -> "ENDED"
                    else -> "UNKNOWN($playbackState)"
                }
                Log.d(TAG, "Playback state: $stateName")
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                Log.d(TAG, "isPlaying=$isPlaying")
                if (isPlaying) {
                    _events.tryEmit(Event.Playing)
                }
            }
        })

        newPlayer.setMediaSource(source)
        newPlayer.prepare()
        newPlayer.play()
        exoPlayer = newPlayer

        return newPlayer
    }

    fun pause() {
        Log.d(TAG, "pause")
        releasePlayer()
        _events.tryEmit(Event.Paused)
    }

    fun resume(): ExoPlayer {
        Log.d(TAG, "resume")
        return start()
    }

    fun stop() {
        Log.d(TAG, "stop")
        releasePlayer()
        _events.tryEmit(Event.Stopped)
    }

    private fun releasePlayer() {
        if (exoPlayer != null) {
            Log.d(TAG, "Releasing ExoPlayer")
        }
        exoPlayer?.stop()
        exoPlayer?.release()
        exoPlayer = null
    }
}
