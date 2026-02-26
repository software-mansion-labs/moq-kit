package com.swmansion.moqsubscriber

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.exoplayer.ExoPlayer
import com.swmansion.moqkit.MoQSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")
    var broadcastPath by mutableStateOf("anon/bbb")
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    var broadcastInfo by mutableStateOf<MoQSession.BroadcastInfo?>(null)
    var player by mutableStateOf<ExoPlayer?>(null)

    private var session: MoQSession? = null
    private var sessionJobs: List<Job> = emptyList()

    fun connect() {
        val context = getApplication<Application>()
        val s = MoQSession(url = relayUrl, path = broadcastPath, parentScope = viewModelScope)
        session = s

        sessionJobs = listOf(
            viewModelScope.launch {
                s.state.collect { sessionState = it }
            },
            viewModelScope.launch {
                s.broadcasts.collect { info ->
                    broadcastInfo = info
                    val videoIdx = info.videoTracks.firstOrNull()?.index?.toUInt()
                    val audioIdx = info.audioTracks.firstOrNull()?.index?.toUInt()
                    player = s.startTrack(
                        context = context,
                        videoIndex = videoIdx,
                        audioIndex = audioIdx,
                    )
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
        val s = session
        session = null
        broadcastInfo = null
        player = null
        sessionState = MoQSession.State.Idle
        viewModelScope.launch { s?.close() }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch { session?.close() }
    }
}
