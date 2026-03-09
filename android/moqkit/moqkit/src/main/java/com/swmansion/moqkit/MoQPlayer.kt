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
import uniffi.moq.AudioConfig
import uniffi.moq.VideoConfig

class MoQPlayer(
    private val context: Context,
    private val broadcastHandle: UInt,
    private val videoTrack: IndexedValue<VideoConfig>?,
    private val audioTrack: IndexedValue<AudioConfig>?,
    private val maxLatencyMs: ULong,
    parentScope: CoroutineScope,
) {
    sealed class Event {
        object Playing : Event()
        data class Error(val code: Int, val message: String) : Event()
        object Stopped : Event()
    }

    private val scope = CoroutineScope(parentScope.coroutineContext + SupervisorJob())

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 8)
    val events: SharedFlow<Event> = _events

    var exoPlayer: ExoPlayer? = null
        private set

    fun start(): ExoPlayer {
        stop()

        val videoConfig = videoTrack?.value
        val audioConfig = audioTrack?.value

        val videoFormat = videoConfig?.let { MediaFactory.makeVideoFormatMedia3(it) }
        val audioFormat = audioConfig?.let { MediaFactory.makeAudioFormatMedia3(it) }

        val videoFlow = videoTrack?.let {
            subscribeVideoTrack(broadcastHandle, it.index.toUInt(), maxLatencyMs)
        }
        val audioFlow = audioTrack?.let {
            subscribeAudioTrack(broadcastHandle, it.index.toUInt(), maxLatencyMs)
        }

        val source = MoQMediaSource(videoFormat, audioFormat, videoFlow, audioFlow, scope)
        val newPlayer = ExoPlayer.Builder(context).build()

        newPlayer.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                Log.e("MoQPlayer", "Player error: ${error.errorCodeName} cause=${error.cause}", error)
                _events.tryEmit(Event.Error(error.errorCode, error.errorCodeName))
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                Log.d("MoQPlayer", "Player state change $playbackState")
                if (playbackState == Player.STATE_READY) {
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

    fun stop() {
        exoPlayer?.stop()
        exoPlayer?.release()
        exoPlayer = null
        _events.tryEmit(Event.Stopped)
    }
}
