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
import com.swmansion.moqkit.MoQRealTimePlayer
import com.swmansion.moqkit.MoQSession
import com.swmansion.moqkit.PlaybackStats
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class BroadcastEntry(info: MoQBroadcastInfo) {
    val id: String = info.path
    var info by mutableStateOf(info)
    var player by mutableStateOf<ExoPlayer?>(null)
    var offline by mutableStateOf(false)
    var isPlaying by mutableStateOf(false)
    var isPaused by mutableStateOf(false)

    var playbackStats by mutableStateOf<PlaybackStats?>(null)

    internal var moqPlayer: MoQPlayer? = null
    var realTimePlayer by mutableStateOf<MoQRealTimePlayer?>(null)
    internal var eventJob: Job? = null
    internal var statsJob: Job? = null
}

enum class PlayerMode { Regular, RealTime }

class MainViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    var playerMode by mutableStateOf(PlayerMode.Regular)
    var targetLatencyMs by mutableStateOf(100)
    val broadcasts = mutableStateListOf<BroadcastEntry>()

    private var session: MoQSession? = null
    private var sessionJobs: List<Job> = emptyList()
    private var latencyUpdateJob: Job? = null

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
                                existing.realTimePlayer?.stop()
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

    fun switchPlayerMode(mode: PlayerMode) {
        if (mode == playerMode) return
        playerMode = mode
        val context = getApplication<Application>()
        for (entry in broadcasts) {
            if (entry.offline) continue
            stopEntry(entry)
            startPlayer(context, entry)
        }
    }

    fun updateTargetLatency(ms: Int) {
        targetLatencyMs = ms
        latencyUpdateJob?.cancel()
        latencyUpdateJob = viewModelScope.launch {
            delay(300) // 300ms debounce, matching iOS
            for (entry in broadcasts) {
                entry.realTimePlayer?.updateTargetLatency(ms)
            }
        }
    }

    private fun stopEntry(entry: BroadcastEntry) {
        entry.eventJob?.cancel()
        entry.statsJob?.cancel()
        entry.moqPlayer?.stop()
        entry.realTimePlayer?.stop()
        entry.moqPlayer = null
        entry.realTimePlayer = null
        entry.player = null
        entry.playbackStats = null
        entry.isPlaying = false
        entry.isPaused = false
    }

    private fun startPlayer(context: Application, entry: BroadcastEntry) {
        val hasAudio = entry.info.audioTracks.isNotEmpty()

        if (playerMode == PlayerMode.RealTime && hasAudio) {
            val allTracks = buildList<com.swmansion.moqkit.MoQTrackInfo> {
                addAll(entry.info.audioTracks)
                addAll(entry.info.videoTracks)
            }
            val rtPlayer = MoQRealTimePlayer(allTracks, targetLatencyMs, viewModelScope)
            entry.realTimePlayer = rtPlayer
            rtPlayer.play()

            entry.eventJob = viewModelScope.launch {
                rtPlayer.events.collect { ev ->
                    when (ev) {
                        is MoQRealTimePlayer.Event.TrackPlaying -> {
                            entry.isPlaying = true
                            entry.isPaused = false
                        }
                        is MoQRealTimePlayer.Event.TrackStopped -> entry.isPlaying = false
                        is MoQRealTimePlayer.Event.Error -> entry.isPlaying = false
                        is MoQRealTimePlayer.Event.AllTracksStopped -> entry.isPlaying = false
                    }
                }
            }
            entry.statsJob = viewModelScope.launch {
                while (true) {
                    delay(500)
                    entry.playbackStats = rtPlayer.stats
                }
            }
            return
        }

        // Regular player: use ExoPlayer for video+audio
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
            entry.realTimePlayer?.pause()
            entry.isPaused = true
        }
    }

    fun resume() {
        for (entry in broadcasts) {
            entry.player = entry.moqPlayer?.resume()
            // Real-time player doesn't support resume — would need to re-play
            entry.isPaused = false
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
