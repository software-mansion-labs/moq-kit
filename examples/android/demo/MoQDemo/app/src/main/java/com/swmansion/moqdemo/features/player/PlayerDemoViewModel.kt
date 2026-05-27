package com.swmansion.moqdemo.features.player

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.Session
import com.swmansion.moqkit.subscribe.AudioTrackInfo
import com.swmansion.moqkit.subscribe.Broadcast
import com.swmansion.moqkit.subscribe.BroadcastSubscription
import com.swmansion.moqkit.subscribe.Catalog
import com.swmansion.moqkit.subscribe.PlaybackStats
import com.swmansion.moqkit.subscribe.Player
import com.swmansion.moqkit.subscribe.PlayerEvent
import com.swmansion.moqkit.subscribe.PlayerEventType
import com.swmansion.moqkit.subscribe.PlayerTrackEvent
import com.swmansion.moqkit.subscribe.PlayerTrackKind
import com.swmansion.moqkit.subscribe.VideoTrackInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant

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
    var startupDiagnostics by mutableStateOf(PlayerStartupDiagnostics())
    var selectedVideoTrack by mutableStateOf<VideoTrackInfo?>(null)
    var selectedAudioTrack by mutableStateOf<AudioTrackInfo?>(null)
    var pendingVideoTrack by mutableStateOf<VideoTrackInfo?>(null)

    internal var eventJob: Job? = null
    internal var statsJob: Job? = null
    internal var latencyUpdateJob: Job? = null
}

class PlayerDemoViewModel(application: Application) : AndroidViewModel(application) {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443/anon")
    var broadcastPath by mutableStateOf("")

    var sessionState by mutableStateOf<Session.State>(Session.State.Idle)
    val broadcasts = mutableStateListOf<BroadcastEntry>()

    private var session: Session? = null
    private var sessionJobs: List<Job> = emptyList()
    private val catalogJobs = mutableMapOf<String, Job>()
    private var subscription: BroadcastSubscription? = null

    fun connect() {
        stop()

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
                    val newSubscription = s.subscribe(prefix = broadcastPath)
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
            entry.player?.updateTargetLatency(Duration.ofMillis(entry.targetLatencyMs.toLong()))
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
            entry.player?.updateTargetLatency(Duration.ofMillis(ms.toLong()))
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
        if (!track.isPlayable) return
        val player = entry.player ?: return
        entry.pendingVideoTrack = track
        try {
            player.switchTrack(track.name)
        } catch (_: Exception) {
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
        val preferredAudioName = existing?.selectedAudioTrack?.name

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
            startPlayer(
                existing,
                preferredVideoName = preferredVideoName,
                preferredAudioName = preferredAudioName,
            )
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
        entry.startupDiagnostics = PlayerStartupDiagnostics()
        entry.isPlaying = false
        entry.isPaused = false
        entry.selectedVideoTrack = null
        entry.selectedAudioTrack = null
        entry.pendingVideoTrack = null
    }

    private fun hasPlayableTracks(catalog: Catalog): Boolean {
        return catalog.playableVideoTracks.isNotEmpty() || catalog.playableAudioTracks.isNotEmpty()
    }

    private fun startPlayer(
        entry: BroadcastEntry,
        preferredVideoName: String?,
        preferredAudioName: String? = null,
    ) {
        val catalog = entry.catalog
        val initialVideo = preferredVideoTrack(catalog, preferredVideoName)
        val initialAudio = preferredAudioTrack(catalog, preferredAudioName)
        if (initialVideo == null && initialAudio == null) {
            return
        }

        val player = try {
            Player(
                catalog = catalog,
                videoTrackName = initialVideo?.name,
                audioTrackName = initialAudio?.name,
                targetBuffering = Duration.ofMillis(entry.targetLatencyMs.toLong()),
                parentScope = viewModelScope,
                volume = entry.volume,
            )
        } catch (_: IllegalArgumentException) {
            return
        }
        entry.player = player
        entry.selectedVideoTrack = initialVideo
        entry.selectedAudioTrack = initialAudio
        entry.startupDiagnostics = PlayerStartupDiagnostics()

        entry.eventJob = viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
            player.events.collect { event ->
                handlePlayerEvent(entry, event)
            }
        }
        entry.statsJob = viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
            player.statsUpdates.collect { stats ->
                entry.playbackStats = stats
            }
        }

        try {
            player.play()
            player.setVolume(entry.volume)
        } catch (_: Exception) {
            entry.offline = true
            stopEntry(entry)
        }
    }

    private fun handlePlayerEvent(entry: BroadcastEntry, event: PlayerEvent) {
        entry.startupDiagnostics = entry.startupDiagnostics.record(event)

        when (val type = event.type) {
            is PlayerEventType.PlaybackStart -> {
                entry.isPlaying = true
                entry.isPaused = false
                applyActiveTrack(entry, type.playback.track)
            }

            is PlayerEventType.PlaybackPause -> {
                entry.isPaused = true
            }

            is PlayerEventType.PlaybackResume -> {
                entry.isPaused = false
            }

            is PlayerEventType.TrackSelect -> {
                when (type.selection.kind) {
                    PlayerTrackKind.VIDEO -> {
                        if (type.selection.trackName == null) {
                            entry.selectedVideoTrack = null
                        }
                    }

                    PlayerTrackKind.AUDIO -> {
                        entry.selectedAudioTrack = entry.catalog.playableAudioTracks
                            .firstOrNull { it.name == type.selection.trackName }
                    }
                }
            }

            is PlayerEventType.TrackPlaying -> {
                applyActiveTrack(entry, type.playing.track)
            }

            is PlayerEventType.TrackSwitch -> {
                applyActiveTrack(entry, type.track)
            }

            is PlayerEventType.TrackSubscribeError -> {
                if (type.error.track.kind == PlayerTrackKind.VIDEO) {
                    entry.pendingVideoTrack = null
                }
            }

            is PlayerEventType.PlaybackEnd -> {
                entry.isPlaying = false
                entry.isPaused = false
                entry.offline = true
                entry.playbackStats = null
            }

            else -> Unit
        }
    }

    private fun applyActiveTrack(entry: BroadcastEntry, track: PlayerTrackEvent) {
        when (track.kind) {
            PlayerTrackKind.VIDEO -> {
                val trackName = track.trackName
                if (trackName != null) {
                    entry.selectedVideoTrack = entry.catalog.playableVideoTracks
                        .firstOrNull { it.name == trackName }
                } else {
                    entry.selectedVideoTrack = entry.pendingVideoTrack
                }
                if (entry.pendingVideoTrack?.name == entry.selectedVideoTrack?.name || trackName == null) {
                    entry.pendingVideoTrack = null
                }
            }

            PlayerTrackKind.AUDIO -> {
                entry.selectedAudioTrack = entry.catalog.playableAudioTracks
                    .firstOrNull { it.name == track.trackName }
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
            catalog.playableVideoTracks.firstOrNull { it.name == preferredName }?.let { return it }
        }
        return catalog.playableVideoTracks.maxByOrNull { track ->
            (track.config.coded?.height ?: 0u) * (track.config.coded?.width ?: 0u)
        }
    }

    private fun preferredAudioTrack(catalog: Catalog, preferredName: String?): AudioTrackInfo? {
        if (preferredName != null) {
            catalog.playableAudioTracks.firstOrNull { it.name == preferredName }?.let { return it }
        }
        return catalog.playableAudioTracks.firstOrNull()
    }
}

data class PlayerStartupDiagnostics(
    val playerInitAt: Instant? = null,
    val playRequestedAt: Instant? = null,
    val playbackStartedAt: Instant? = null,
    val playbackEndedAt: Instant? = null,
    val playbackStartedByKind: PlayerTrackKind? = null,
    val orderedTracks: List<TrackStartupDiagnostics> = emptyList(),
) {
    val initToPlayRequest: Duration?
        get() = elapsed(playerInitAt, playRequestedAt)

    val playRequestToPlaybackStart: Duration?
        get() = elapsed(playRequestedAt, playbackStartedAt)

    fun record(event: PlayerEvent): PlayerStartupDiagnostics {
        return when (val type = event.type) {
            is PlayerEventType.PlayerInit -> copy(
                playerInitAt = playerInitAt ?: event.timestamp,
            )

            is PlayerEventType.PlaybackRequest -> copy(
                playRequestedAt = event.timestamp,
                playbackStartedAt = null,
                playbackEndedAt = null,
                playbackStartedByKind = null,
                orderedTracks = emptyList(),
            )

            is PlayerEventType.PlaybackStart -> copy(
                playbackStartedAt = playbackStartedAt ?: event.timestamp,
                playbackStartedByKind = type.playback.track.kind,
            )

            is PlayerEventType.PlaybackEnd -> copy(
                playbackEndedAt = event.timestamp,
            )

            is PlayerEventType.TrackSubscribeStart -> startTrack(event, type.track)

            is PlayerEventType.TrackReady -> updateTrack(event, type.ready.track) { track ->
                track.copy(
                    trackName = type.ready.track.trackName ?: track.trackName,
                    readyAt = track.readyAt ?: event.timestamp,
                    epoch = type.ready.track.epoch,
                )
            }

            is PlayerEventType.TrackPlaying -> updateTrack(event, type.playing.track) { track ->
                track.copy(
                    trackName = type.playing.track.trackName ?: track.trackName,
                    playingAt = track.playingAt ?: event.timestamp,
                    epoch = type.playing.track.epoch,
                )
            }

            is PlayerEventType.TrackSubscribeError -> updateTrack(event, type.error.track) { track ->
                track.copy(
                    trackName = type.error.track.trackName ?: track.trackName,
                    errorAt = event.timestamp,
                    errorMessage = type.error.message,
                    epoch = type.error.track.epoch,
                )
            }

            is PlayerEventType.TrackSubscribeEnd -> updateTrack(event, type.track) { track ->
                track.copy(
                    trackName = type.track.trackName ?: track.trackName,
                    endedAt = event.timestamp,
                    epoch = type.track.epoch,
                )
            }

            is PlayerEventType.TrackSwitch -> updateTrack(event, type.track) { track ->
                track.copy(
                    trackName = type.track.trackName ?: track.trackName,
                    activeAt = track.activeAt ?: event.timestamp,
                    epoch = type.track.epoch,
                )
            }

            else -> this
        }
    }

    private fun startTrack(
        event: PlayerEvent,
        eventTrack: PlayerTrackEvent,
    ): PlayerStartupDiagnostics {
        val track = TrackStartupDiagnostics(
            id = "track-${event.sequence}",
            kind = eventTrack.kind,
            trackName = eventTrack.trackName,
            subscribeStartedAt = event.timestamp,
            epoch = eventTrack.epoch,
        )
        return copy(orderedTracks = orderedTracks + track)
    }

    private fun updateTrack(
        event: PlayerEvent,
        eventTrack: PlayerTrackEvent,
        update: (TrackStartupDiagnostics) -> TrackStartupDiagnostics,
    ): PlayerStartupDiagnostics {
        val index = orderedTracks.indices.reversed().firstOrNull { index ->
            val track = orderedTracks[index]
            if (track.kind != eventTrack.kind) return@firstOrNull false
            val eventTrackName = eventTrack.trackName
            val existingName = track.trackName
            if (eventTrackName != null && existingName != null && existingName != eventTrackName) {
                return@firstOrNull false
            }
            if (eventTrack.epoch != 0L && track.epoch != eventTrack.epoch) {
                return@firstOrNull false
            }
            true
        }

        if (index != null) {
            val tracks = orderedTracks.toMutableList()
            tracks[index] = update(tracks[index])
            return copy(orderedTracks = tracks)
        }

        val track = update(
            TrackStartupDiagnostics(
                id = "track-${event.sequence}",
                kind = eventTrack.kind,
                epoch = eventTrack.epoch,
            ),
        )
        return copy(orderedTracks = orderedTracks + track)
    }
}

data class TrackStartupDiagnostics(
    val id: String,
    val kind: PlayerTrackKind,
    val trackName: String? = null,
    val subscribeStartedAt: Instant? = null,
    val readyAt: Instant? = null,
    val playingAt: Instant? = null,
    val activeAt: Instant? = null,
    val errorAt: Instant? = null,
    val errorMessage: String? = null,
    val endedAt: Instant? = null,
    val epoch: Long = 0L,
) {
    val isTrackSwitch: Boolean
        get() = epoch > 1L

    val operationLabel: String
        get() = if (isTrackSwitch) "Switch" else "Play request"

    fun subscribeToReady(): Duration? = elapsed(subscribeStartedAt, readyAt)

    fun operationToReady(playRequestedAt: Instant?): Duration? {
        return elapsed(operationStartedAt(playRequestedAt), readyAt)
    }

    fun readyToPlaying(): Duration? = elapsed(readyAt, playingAt)

    fun operationToPlaying(playRequestedAt: Instant?): Duration? {
        return elapsed(operationStartedAt(playRequestedAt), playingAt)
    }

    fun operationToActive(playRequestedAt: Instant?): Duration? {
        return elapsed(operationStartedAt(playRequestedAt), activeAt)
    }

    private fun operationStartedAt(playRequestedAt: Instant?): Instant? {
        return if (isTrackSwitch) subscribeStartedAt else playRequestedAt
    }
}

private fun elapsed(from: Instant?, to: Instant?): Duration? {
    if (from == null || to == null) return null
    return Duration.between(from, to)
}
