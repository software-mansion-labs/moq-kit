package com.swmansion.moqdemo.features.player

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.subscribe.Broadcast
import com.swmansion.moqkit.subscribe.BroadcastSubscription
import com.swmansion.moqkit.subscribe.Catalog
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.Player
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class BroadcastEntry(catalog: Catalog) {
    val id: String = catalog.path
    var catalog by mutableStateOf(catalog)
    var player by mutableStateOf<Player?>(null)
    var offline by mutableStateOf(false)
    var isPlaying by mutableStateOf(false)
    var isPaused by mutableStateOf(false)
    var targetLatencyMs by mutableStateOf(200)
    var volume by mutableStateOf(1f)
    var lastNonZeroVolume by mutableStateOf(1f)

    var playbackStats by mutableStateOf<PlaybackStats?>(null)
    var selectedVideoTrack by mutableStateOf<VideoTrackInfo?>(null)
    var pendingVideoTrack by mutableStateOf<VideoTrackInfo?>(null)

    internal var eventJob: Job? = null
    internal var statsJob: Job? = null
    internal var latencyUpdateJob: Job? = null
}

class PlayerDemoViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")

    var sessionState by mutableStateOf<Session.State>(Session.State.Idle)
    val broadcasts = mutableStateListOf<BroadcastEntry>()

    private var session: Session? = null
    private var sessionJobs: List<Job> = emptyList()
    private val catalogJobs = mutableMapOf<String, Job>()
    private var subscription: BroadcastSubscription? = null

    fun connect() {
        val s = Session(
            url = relayUrl,
            parentScope = viewModelScope,
        )
        session = s

        sessionJobs = listOf(
            viewModelScope.launch {
                s.state.collect { sessionState = it }
            },
            viewModelScope.launch {
                try {
                    s.connect()
                    val newSubscription = s.subscribe()
                    subscription = newSubscription
                    newSubscription.broadcasts.collect { broadcast ->
                        observeCatalogs(broadcast)
                    }
                } catch (_: Exception) {
                }
            },
        )
    }

    fun togglePause(entry: BroadcastEntry) {
        if (entry.isPaused) {
            entry.player?.play()
            // play() recreates renderers with the original constructor latency — restore the slider value
            entry.player?.updateTargetLatency(entry.targetLatencyMs)
            entry.player?.setVolume(entry.volume)
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

    fun updateVolume(entry: BroadcastEntry, volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)
        entry.volume = clamped
        if (clamped > 0f) {
            entry.lastNonZeroVolume = clamped
        }
        entry.player?.setVolume(clamped)
    }

    fun toggleMute(entry: BroadcastEntry) {
        if (entry.volume > 0f) {
            updateVolume(entry, 0f)
        } else {
            updateVolume(entry, entry.lastNonZeroVolume.takeIf { it > 0f } ?: 1f)
        }
    }

    fun switchVideoTrack(entry: BroadcastEntry, track: VideoTrackInfo) {
        entry.pendingVideoTrack = track
        try {
            entry.player?.switchTrack(track.name)
            entry.selectedVideoTrack = track
        } finally {
            entry.pendingVideoTrack = null
        }
    }

    private fun observeCatalogs(broadcast: Broadcast) {
        catalogJobs.remove(broadcast.path)?.cancel()
        catalogJobs[broadcast.path] = viewModelScope.launch {
            try {
                broadcast.catalogs().collect { catalog ->
                    replaceBroadcast(catalog)
                }
                markBroadcastUnavailable(broadcast.path)
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                markBroadcastUnavailable(broadcast.path)
            } finally {
                if (catalogJobs[broadcast.path] === coroutineContext[Job]) {
                    catalogJobs.remove(broadcast.path)
                }
                broadcast.close()
            }
        }
    }

    private fun cancelCatalogJobs() {
        val jobs = catalogJobs.values.toList()
        catalogJobs.clear()
        jobs.forEach { it.cancel() }
    }

    private fun replaceBroadcast(catalog: Catalog) {
        val existing = broadcasts.find { it.id == catalog.path }
        val preferredVideoName = existing?.selectedVideoTrack?.name

        if (existing == null) {
            val entry = BroadcastEntry(catalog)
            broadcasts.add(entry)
            if (hasPlayableTracks(catalog)) {
                startPlayer(entry, preferredVideoName = null)
            }
            return
        }

        stopEntry(existing)
        existing.catalog = catalog
        existing.offline = false
        if (hasPlayableTracks(catalog)) {
            startPlayer(existing, preferredVideoName = preferredVideoName)
        }
    }

    private fun markBroadcastUnavailable(path: String) {
        val entry = broadcasts.find { it.id == path } ?: return
        stopEntry(entry)
        entry.offline = true
    }

    private fun stopEntry(entry: BroadcastEntry) {
        entry.eventJob?.cancel()
        entry.eventJob = null
        entry.statsJob?.cancel()
        entry.statsJob = null
        entry.latencyUpdateJob?.cancel()
        entry.latencyUpdateJob = null
        entry.player?.close()
        entry.player = null
        entry.playbackStats = null
        entry.isPlaying = false
        entry.isPaused = false
        entry.selectedVideoTrack = null
        entry.pendingVideoTrack = null
    }

    private fun hasPlayableTracks(catalog: Catalog): Boolean {
        return catalog.videoTracks.isNotEmpty() || catalog.audioTracks.isNotEmpty()
    }

    private fun startPlayer(entry: BroadcastEntry, preferredVideoName: String?) {
        val catalog = entry.catalog
        val initialVideo = preferredVideoTrack(catalog, preferredVideoName)
        val initialAudioName = catalog.audioTracks.firstOrNull()?.name
        if (initialVideo == null && initialAudioName == null) {
            return
        }

        val player = try {
            Player(
                catalog = catalog,
                videoTrackName = initialVideo?.name,
                audioTrackName = initialAudioName,
                targetLatencyMs = entry.targetLatencyMs,
                parentScope = viewModelScope,
                volume = entry.volume,
            )
        } catch (_: IllegalArgumentException) {
            return
        }
        entry.player = player
        entry.selectedVideoTrack = initialVideo
        player.play()
        player.setVolume(entry.volume)

        entry.eventJob = viewModelScope.launch {
            player.events.collect { ev ->
                when (ev) {
                    is Player.Event.TrackPlaying -> {
                        entry.isPlaying = true
                        entry.isPaused = false
                    }

                    is Player.Event.TrackPaused -> entry.isPaused = true
                    is Player.Event.TrackStopped -> {}
                    is Player.Event.Error -> {}
                    is Player.Event.AllTracksStopped -> {
                        entry.isPlaying = false
                        entry.isPaused = false
                    }
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
        cancelCatalogJobs()
        subscription?.close()
        subscription = null
        for (entry in broadcasts) {
            stopEntry(entry)
        }
        broadcasts.clear()
        val s = session
        session = null
        sessionState = Session.State.Idle
        viewModelScope.launch { s?.close() }
    }

    override fun onCleared() {
        super.onCleared()
        cancelCatalogJobs()
        subscription?.close()
        viewModelScope.launch { session?.close() }
    }

    private fun preferredVideoTrack(catalog: Catalog, preferredName: String?): VideoTrackInfo? {
        if (preferredName != null) {
            catalog.videoTracks.firstOrNull { it.name == preferredName }?.let { return it }
        }
        return catalog.videoTracks.maxByOrNull { track ->
            (track.config.coded?.height ?: 0u) * (track.config.coded?.width ?: 0u)
        }
    }
}
