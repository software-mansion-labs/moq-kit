package com.swmansion.moqsubscriber

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.exoplayer.ExoPlayer
import com.swmansion.moqkit.MoQBroadcastEvent
import com.swmansion.moqkit.MoQBroadcastInfo
import com.swmansion.moqkit.MoQPlayer
import com.swmansion.moqkit.MoQSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class BroadcastEntry(info: MoQBroadcastInfo) {
    val id: String = info.path
    var info by mutableStateOf(info)
    var player by mutableStateOf<ExoPlayer?>(null)
    var offline by mutableStateOf(false)
    var isPlaying by mutableStateOf(false)
    var isPaused by mutableStateOf(false)

    internal var moqPlayer: MoQPlayer? = null
    internal var eventJob: Job? = null
}

class MainViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.236:4443")
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    val broadcasts = mutableStateListOf<BroadcastEntry>()

    private var session: MoQSession? = null
    private var sessionJobs: List<Job> = emptyList()

    fun connect() {
        val context = getApplication<Application>()
        val s = MoQSession(
            url = relayUrl,
            parentScope = viewModelScope,
        )
        session = s

        sessionJobs = listOf(
            viewModelScope.launch {
                s.state.collect { sessionState = it }
            },
            viewModelScope.launch {
                s.broadcasts.collect { event ->
                    when (event) {
                        is MoQBroadcastEvent.Available -> {
                            val info = event.info
                            val existing = broadcasts.find { it.id == info.path }
                            if (existing != null) {
                                existing.moqPlayer?.stop()
                                existing.eventJob?.cancel()
                                existing.info = info
                                existing.offline = false
                                startPlayer(context, existing)
                            } else {
                                val entry = BroadcastEntry(info)
                                broadcasts.add(entry)
                                startPlayer(context, entry)
                            }
                        }
                        is MoQBroadcastEvent.Unavailable -> {
                            val entry = broadcasts.find { it.id == event.path } ?: return@collect
                            entry.moqPlayer?.stop()
                            entry.moqPlayer = null
                            entry.player = null
                            entry.isPlaying = false
                            entry.isPaused = false
                            entry.offline = true
                        }
                    }
                }
            },
            viewModelScope.launch {
                try { s.connect() } catch (_: Exception) {}
            },
        )
    }

    private fun startPlayer(context: Application, entry: BroadcastEntry) {
        val tracks = buildList {
            entry.info.videoTracks.firstOrNull()?.let { add(it) }
            entry.info.audioTracks.firstOrNull()?.let { add(it) }
        }
        val newPlayer = MoQPlayer(context, tracks, 500u, viewModelScope)
        entry.moqPlayer = newPlayer
        entry.player = newPlayer.start()

        entry.eventJob = viewModelScope.launch {
            newPlayer.events.collect { ev ->
                when (ev) {
                    is MoQPlayer.Event.Playing -> {
                        entry.isPlaying = true
                        entry.isPaused = false
                    }
                    is MoQPlayer.Event.Paused -> entry.isPlaying = false
                    is MoQPlayer.Event.Error -> entry.isPlaying = false
                    is MoQPlayer.Event.Stopped -> entry.isPlaying = false
                }
            }
        }
    }

    fun pause() {
        for (entry in broadcasts) {
            entry.moqPlayer?.pause()
            entry.isPaused = true
        }
    }

    fun resume() {
        for (entry in broadcasts) {
            entry.player = entry.moqPlayer?.resume()
            entry.isPaused = false
        }
    }

    fun stop() {
        sessionJobs.forEach { it.cancel() }
        sessionJobs = emptyList()
        for (entry in broadcasts) {
            entry.eventJob?.cancel()
            entry.moqPlayer?.stop()
        }
        broadcasts.clear()
        val s = session
        session = null
        sessionState = MoQSession.State.Idle
        viewModelScope.launch { s?.close() }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch { session?.close() }
    }
}
