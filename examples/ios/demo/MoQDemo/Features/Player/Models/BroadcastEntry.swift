import AVFoundation
import MoQKit
import os

private let broadcastEntryLogger = Logger(
    subsystem: "com.swmansion.MoQDemo",
    category: "broadcast-entry"
)

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    let broadcastPath: String
    let audioAnalysis = BroadcastAudioAnalysis()

    @Published var selectedVideoTrackName: String?
    @Published var selectedAudioTrackName: String?
    @Published var catalog: Catalog
    @Published var player: Player?
    @Published var offline = false
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var playbackStats: PlaybackStats?
    @Published var startupDiagnostics = PlayerStartupDiagnostics()
    @Published var targetLatencyMs: Double
    @Published var volume: Double = 1.0

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer
    }

    var hasAudio: Bool {
        selectedAudioTrack != nil
    }

    private var eventsSubscription: PlayerEventSubscription?
    private var statsSubscription: PlayerEventSubscription?
    private var pendingVideoTrackName: String?
    private var lastNonZeroVolume: Double = 1.0

    var selectedVideoTrack: VideoTrackInfo? {
        guard let selectedVideoTrackName else { return nil }
        return catalog.playableVideoTracks.first(where: { $0.name == selectedVideoTrackName })
    }

    var selectedAudioTrack: AudioTrackInfo? {
        guard let selectedAudioTrackName else { return nil }
        return catalog.playableAudioTracks.first(where: { $0.name == selectedAudioTrackName })
    }

    var canStartAudioAnalysis: Bool {
        selectedAudioTrack != nil && !offline
    }

    init(
        catalog: Catalog,
        initialVideoTrackName: String?,
        initialAudioTrackName: String?,
        initialLatencyMs: UInt64
    ) {
        self.id = catalog.path
        self.broadcastPath = catalog.path
        self.selectedVideoTrackName = initialVideoTrackName
        self.selectedAudioTrackName = initialAudioTrackName
        self.catalog = catalog
        self.targetLatencyMs = Double(initialLatencyMs)
    }

    func attach(player: Player) {
        broadcastEntryLogger.debug(
            "Attaching player path=\(self.broadcastPath), video=\(self.selectedVideoTrackName ?? "none"), audio=\(self.selectedAudioTrackName ?? "none")"
        )
        self.player = player
        eventsSubscription?.cancel()
        eventsSubscription = player.subscribeEvents { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func switchVideoTrack(to trackName: String) {
        guard catalog.playableVideoTracks.contains(where: { $0.name == trackName }) else { return }
        pendingVideoTrackName = trackName
        Task { try? await player?.switchTrack(to: trackName) }
    }

    // TODO: expose audio-track switching parity with switchVideoTrack - wire through
    // `player?.switchAudioTrack(to:)` and update `selectedAudioTrackName` from
    // `track.select` / `track.switch`. The field is currently set once in `init`.

    func updateTargetLatency(ms: UInt64) {
        targetLatencyMs = Double(ms)
        player?.updateTargetLatency(.milliseconds(Int64(min(ms, UInt64(Int64.max)))))
    }

    func updateVolume(_ newVolume: Double) {
        let clampedVolume = min(max(newVolume, 0), 1)
        volume = clampedVolume
        if clampedVolume > 0 {
            lastNonZeroVolume = clampedVolume
        }
        player?.setVolume(Float(clampedVolume))
    }

    func toggleMute() {
        if volume > 0 {
            updateVolume(0)
        } else {
            updateVolume(lastNonZeroVolume)
        }
    }

    func stop(reason: String = "entry stop requested") async {
        broadcastEntryLogger.debug(
            "Stopping broadcast entry path=\(self.broadcastPath), reason=\(reason), hasPlayer=\(self.player != nil), isPlaying=\(self.isPlaying), isPaused=\(self.isPaused), offline=\(self.offline)"
        )
        audioAnalysis.stop(reset: true)
        eventsSubscription?.cancel()
        eventsSubscription = nil
        statsSubscription?.cancel()
        statsSubscription = nil
        playbackStats = nil
        await player?.stopAll(reason: reason)
        player = nil
        isPlaying = false
    }

    private func handleEvent(_ event: PlayerEvent) {
        broadcastEntryLogger.debug(
            "Player event path=\(self.broadcastPath), event=\(event.name.rawValue)"
        )

        startupDiagnostics.record(
            event,
            activeVideoTrackName: selectedVideoTrackName,
            activeAudioTrackName: selectedAudioTrackName
        )

        switch event.type {
        case .playbackStart(_):
            isPlaying = true
            isPaused = false
            startStatsSubscription()
        case .playbackPause(_):
            isPaused = true
        case .playbackResume(_):
            isPaused = false
        case .trackSwitch(let track):
            if track.kind == .video {
                if let trackName = track.trackName {
                    selectedVideoTrackName = trackName
                    self.pendingVideoTrackName = nil
                } else if let pendingVideoTrackName {
                    selectedVideoTrackName = pendingVideoTrackName
                    self.pendingVideoTrackName = nil
                }
            }
        case .playbackEnd(_):
            isPlaying = false
            isPaused = false
            offline = true
            audioAnalysis.stop()
            statsSubscription?.cancel()
            statsSubscription = nil
            playbackStats = nil
        default:
            break
        }
    }

    private func startStatsSubscription() {
        guard statsSubscription == nil, let player else { return }

        statsSubscription = player.subscribeStats { [weak self] stats in
            self?.playbackStats = stats
        }
    }
}

struct PlayerStartupDiagnostics {
    var playerInitAt: ContinuousClock.Instant?
    var playRequestedAt: ContinuousClock.Instant?
    var playbackStartedAt: ContinuousClock.Instant?
    var playbackEndedAt: ContinuousClock.Instant?
    var playbackStartedByKind: PlayerTrackKind?
    private var tracks: [TrackStartupDiagnostics] = []

    var initToPlayRequest: Duration? {
        elapsed(from: playerInitAt, to: playRequestedAt)
    }

    var playRequestToPlaybackStart: Duration? {
        elapsed(from: playRequestedAt, to: playbackStartedAt)
    }

    var orderedTracks: [TrackStartupDiagnostics] {
        tracks
    }

    mutating func record(
        _ event: PlayerEvent,
        activeVideoTrackName: String?,
        activeAudioTrackName: String?
    ) {
        switch event.type {
        case .playerInit(_):
            playerInitAt = playerInitAt ?? event.timestamp
        case .playbackRequest(_):
            playRequestedAt = event.timestamp
            playbackStartedAt = nil
            playbackEndedAt = nil
            playbackStartedByKind = nil
            tracks.removeAll()
        case .playbackStart(let playback):
            playbackStartedAt = playbackStartedAt ?? event.timestamp
            playbackStartedByKind = playback.track.kind
        case .playbackEnd(_):
            playbackEndedAt = event.timestamp
        case .trackSubscribeStart(let track):
            startTrack(
                event,
                track,
                activeTrackName: track.kind == .video
                    ? activeVideoTrackName
                    : activeAudioTrackName
            )
        case .trackReady(let ready):
            updateTrack(event, ready.track) { track in
                track.trackName = ready.track.trackName ?? track.trackName
                track.readyAt = track.readyAt ?? event.timestamp
                track.epoch = ready.track.epoch
            }
        case .trackPlaying(let playing):
            updateTrack(event, playing.track) { track in
                track.trackName = playing.track.trackName ?? track.trackName
                track.playingAt = track.playingAt ?? event.timestamp
                track.epoch = playing.track.epoch
            }
        case .trackSubscribeError(let error):
            updateTrack(event, error.track) { track in
                track.trackName = error.track.trackName ?? track.trackName
                track.errorAt = event.timestamp
                track.errorMessage = error.message
                track.epoch = error.track.epoch
            }
        case .trackSubscribeEnd(let eventTrack):
            updateTrack(event, eventTrack) { track in
                track.trackName = eventTrack.trackName ?? track.trackName
                track.endedAt = event.timestamp
                track.epoch = eventTrack.epoch
            }
        case .trackSwitch(let eventTrack):
            updateTrack(event, eventTrack) { track in
                track.trackName = eventTrack.trackName ?? track.trackName
                track.activeAt = track.activeAt ?? event.timestamp
                track.epoch = eventTrack.epoch
            }
        default:
            break
        }
    }

    func elapsed(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant?
    ) -> Duration? {
        guard let start, let end else { return nil }
        return start.duration(to: end)
    }

    private mutating func startTrack(
        _ event: PlayerEvent,
        _ eventTrack: PlayerTrackEvent,
        activeTrackName: String?
    ) {
        var track = TrackStartupDiagnostics(id: "track-\(event.sequence)", kind: eventTrack.kind)
        track.trackName = eventTrack.trackName
        track.subscribeStartedAt = event.timestamp
        track.epoch = eventTrack.epoch
        if track.isTrackSwitch {
            tracks.removeAll { $0.kind == eventTrack.kind && $0.isTrackSwitch }
            track.sourceTrackName = activeTrackName
        }
        tracks.append(track)
    }

    private mutating func updateTrack(
        _ event: PlayerEvent,
        _ eventTrack: PlayerTrackEvent,
        _ update: (inout TrackStartupDiagnostics) -> Void
    ) {
        if let index = tracks.indices.reversed().first(where: { index in
            let track = tracks[index]
            guard track.kind == eventTrack.kind else { return false }
            if let trackName = eventTrack.trackName,
               let existingName = track.trackName,
               existingName != trackName
            {
                return false
            }
            if eventTrack.epoch != .zero, track.epoch != eventTrack.epoch {
                return false
            }
            return true
        }) {
            update(&tracks[index])
            return
        }

        var track = TrackStartupDiagnostics(id: "track-\(event.sequence)", kind: eventTrack.kind)
        track.epoch = eventTrack.epoch
        update(&track)
        tracks.append(track)
    }
}

struct TrackStartupDiagnostics: Identifiable {
    let id: String
    let kind: PlayerTrackKind
    var sourceTrackName: String?
    var trackName: String?
    var subscribeStartedAt: ContinuousClock.Instant?
    var readyAt: ContinuousClock.Instant?
    var playingAt: ContinuousClock.Instant?
    var activeAt: ContinuousClock.Instant?
    var errorAt: ContinuousClock.Instant?
    var errorMessage: String?
    var endedAt: ContinuousClock.Instant?
    var epoch: UInt64 = .zero

    var isTrackSwitch: Bool {
        epoch > 1
    }

    var operationLabel: String {
        isTrackSwitch ? "Switch" : "Play request"
    }

    func subscribeToReady() -> Duration? {
        elapsed(from: subscribeStartedAt, to: readyAt)
    }

    func operationToReady(playRequestedAt: ContinuousClock.Instant?) -> Duration? {
        elapsed(from: operationStartedAt(playRequestedAt: playRequestedAt), to: readyAt)
    }

    func readyToPlaying() -> Duration? {
        elapsed(from: readyAt, to: playingAt)
    }

    func operationToPlaying(playRequestedAt: ContinuousClock.Instant?) -> Duration? {
        elapsed(from: operationStartedAt(playRequestedAt: playRequestedAt), to: playingAt)
    }

    func operationToActive(playRequestedAt: ContinuousClock.Instant?) -> Duration? {
        elapsed(from: operationStartedAt(playRequestedAt: playRequestedAt), to: activeAt)
    }

    private func operationStartedAt(
        playRequestedAt: ContinuousClock.Instant?
    ) -> ContinuousClock.Instant? {
        isTrackSwitch ? subscribeStartedAt : playRequestedAt
    }

    private func elapsed(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant?
    ) -> Duration? {
        guard let start, let end else { return nil }
        return start.duration(to: end)
    }
}
