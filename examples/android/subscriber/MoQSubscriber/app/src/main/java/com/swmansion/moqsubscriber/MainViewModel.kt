package com.swmansion.moqsubscriber

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.exoplayer.ExoPlayer
import com.swmansion.moqkit.MoQPlayer
import com.swmansion.moqkit.MoQSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")
    var broadcastPath by mutableStateOf("anon/bbb/ccc")
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    var broadcastInfo by mutableStateOf<MoQSession.BroadcastInfo?>(null)
    var player by mutableStateOf<ExoPlayer?>(null)
    var isPlaying by mutableStateOf(false)

    private var session: MoQSession? = null
    private var moqPlayer: MoQPlayer? = null
    private var sessionJobs: List<Job> = emptyList()

    fun connect() {
        val context = getApplication<Application>()
        val s = MoQSession(
            url = relayUrl,
            path = broadcastPath,
            parentScope = viewModelScope,
        )
        session = s

        sessionJobs = listOf(
            viewModelScope.launch {
                s.state.collect { sessionState = it }
            },
            viewModelScope.launch {
                s.broadcasts.collect { info ->
                    broadcastInfo = info
                    val videoIndex = info.videoTracks.firstOrNull()?.index?.toUInt()
                    val audioIndex = info.audioTracks.firstOrNull()?.index?.toUInt()

                    moqPlayer?.stop()
                    val newPlayer = s.makePlayer(context, videoIndex, audioIndex)
                    moqPlayer = newPlayer
                    player = newPlayer.start()

                    viewModelScope.launch {
                        newPlayer.events.collect { event ->
                            when (event) {
                                is MoQPlayer.Event.Playing -> isPlaying = true
                                is MoQPlayer.Event.Error -> isPlaying = false
                                is MoQPlayer.Event.Stopped -> isPlaying = false
                            }
                        }
                    }
                }
            },
            viewModelScope.launch {
                try { s.connect() } catch (_: Exception) {}
            },
        )
    }

    fun stop() {
        sessionJobs.forEach { it.cancel() }
        sessionJobs = emptyList()
        moqPlayer?.stop()
        moqPlayer = null
        val s = session
        session = null
        broadcastInfo = null
        player = null
        isPlaying = false
        sessionState = MoQSession.State.Idle
        viewModelScope.launch { s?.close() }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch { session?.close() }
    }
}
