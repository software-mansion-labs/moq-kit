package com.swmansion.moqsubscriber

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.MoQBroadcastEvent
import com.swmansion.moqkit.MoQBroadcastInfo
import com.swmansion.moqkit.MoQPlayer
import com.swmansion.moqkit.MoQSession
import com.swmansion.moqkit.MoQTrackInfo
import com.swmansion.moqkit.MoQVideoTrackInfo
import com.swmansion.moqkit.PlaybackStats
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch


class BroadcastEntry(info: MoQBroadcastInfo) {
    val id: String = info.path
    var info by mutableStateOf(info)
    var player by mutableStateOf<MoQPlayer?>(null)
    var offline by mutableStateOf(false)
    var isPlaying by mutableStateOf(false)
    var isPaused by mutableStateOf(false)
    var targetLatencyMs by mutableStateOf(200)

    var playbackStats by mutableStateOf<PlaybackStats?>(null)
    var selectedVideoTrack by mutableStateOf<MoQVideoTrackInfo?>(null)
    var pendingVideoTrack by mutableStateOf<MoQVideoTrackInfo?>(null)

    internal var eventJob: Job? = null
    internal var statsJob: Job? = null
    internal var latencyUpdateJob: Job? = null
}

class MainViewModel(application: Application) : AndroidViewModel(application) {
    // var relayUrl by mutableStateOf("http://192.168.92.85:4443")
    var relayUrl = "https://cdn.moq.dev/demo?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb290IjoiZGVtbyIsImdldCI6WyIiXSwiZXhwIjpudWxsLCJpYXQiOm51bGx9.6EoN-Y1Ouj35_qV5FokcdcdderrE2navNbYQjJyR2Ac"

    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    val broadcasts = mutableStateListOf<BroadcastEntry>()

    private var session: MoQSession? = null
    private var sessionJobs: List<Job> = emptyList()

    fun connect() {
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
                                existing.player?.stop()
                                existing.eventJob?.cancel()
                                existing.info = info
                                existing.offline = false
                                startPlayer(existing)
                            } else {
                                val entry = BroadcastEntry(info)
                                broadcasts.add(entry)
                                startPlayer(entry)
                            }
                        }
                        is MoQBroadcastEvent.Unavailable -> {
                            val entry = broadcasts.find { it.id == event.path } ?: return@collect
                            stopEntry(entry)
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
    fun togglePause(entry: BroadcastEntry) {
        if (entry.isPaused) {
            entry.player?.play()
            // play() recreates renderers with the original constructor latency — restore the slider value
            entry.player?.updateTargetLatency(entry.targetLatencyMs)
            entry.isPaused = false
        } else {
            entry.player?.pause()
            entry.isPaused = true
        }
    }

    fun updateTargetLatency(entry: BroadcastEntry, ms: Int) {
        entry.targetLatencyMs = ms
        entry.latencyUpdateJob?.cancel()
        entry.latencyUpdateJob = viewModelScope.launch {
            delay(300) // 300ms debounce, matching iOS
            entry.player?.updateTargetLatency(ms)
        }
    }

    fun switchVideoTrack(entry: BroadcastEntry, track: MoQVideoTrackInfo) {
        entry.pendingVideoTrack = track
        entry.player?.switchVideoTrack(track) {
            viewModelScope.launch(Dispatchers.Main) {
                entry.selectedVideoTrack = track
                entry.pendingVideoTrack = null
            }
        }
    }

    private fun stopEntry(entry: BroadcastEntry) {
        entry.eventJob?.cancel()
        entry.statsJob?.cancel()
        entry.latencyUpdateJob?.cancel()
        entry.player?.stop()
        entry.player = null
        entry.playbackStats = null
        entry.isPlaying = false
        entry.isPaused = false
        entry.selectedVideoTrack = null
        entry.pendingVideoTrack = null
    }

    private fun startPlayer(entry: BroadcastEntry) {
        val initialVideo = entry.info.videoTracks.maxByOrNull { track ->
            (track.config.coded?.height ?: 0u) * (track.config.coded?.width ?: 0u)
        }

        val tracks = buildList<MoQTrackInfo> {
            addAll(entry.info.audioTracks)
            if (initialVideo != null) add(initialVideo)
        }
        val player = MoQPlayer(tracks, entry.targetLatencyMs, viewModelScope)
        entry.player = player
        entry.selectedVideoTrack = initialVideo
        player.play()

        entry.eventJob = viewModelScope.launch {
            player.events.collect { ev ->
                when (ev) {
                    is MoQPlayer.Event.TrackPlaying -> {
                        entry.isPlaying = true
                        entry.isPaused = false
                    }
                    is MoQPlayer.Event.TrackStopped -> entry.isPlaying = false
                    is MoQPlayer.Event.Error -> entry.isPlaying = false
                    is MoQPlayer.Event.AllTracksStopped -> entry.isPlaying = false
                    else -> {}
                }
            }
        }
        entry.statsJob = viewModelScope.launch {
            while (true) {
                delay(500)
                entry.playbackStats = player.stats
            }
        }
    }

    fun stop() {
        sessionJobs.forEach { it.cancel() }
        sessionJobs = emptyList()
        for (entry in broadcasts) {
            stopEntry(entry)
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
