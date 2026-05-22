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
        player?.updateTargetLatency(ms: ms)
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
        eventsSubscription?.cancel()
        eventsSubscription = nil
        stopStatsSubscription()
        await player?.stopAll(reason: reason)
        player = nil
        isPlaying = false
    }

    private func handleEvent(_ event: PlayerEvent) {
        broadcastEntryLogger.debug(
            "Player event path=\(self.broadcastPath), event=\(event.name.rawValue), attributes=\(Self.eventAttributesDescription(event.attributes))"
        )

        startupDiagnostics.record(event)

        switch event.name {
        case .playbackStart:
            isPlaying = true
            isPaused = false
            startStatsSubscription()
        case .playbackPause:
            isPaused = true
        case .playbackResume:
            isPaused = false
        case .trackSwitch:
            if event.string("kind") == "video" {
                if let trackName = event.string("trackName") {
                    selectedVideoTrackName = trackName
                    self.pendingVideoTrackName = nil
                } else if let pendingVideoTrackName {
                    selectedVideoTrackName = pendingVideoTrackName
                    self.pendingVideoTrackName = nil
                }
            }
        case .playbackEnd:
            isPlaying = false
            isPaused = false
            offline = true
            stopStatsSubscription()
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

    private func stopStatsSubscription() {
        statsSubscription?.cancel()
        statsSubscription = nil
        playbackStats = nil
    }

    private static func eventAttributesDescription(
        _ attributes: [String: PlayerEventValue]
    ) -> String {
        guard !attributes.isEmpty else { return "{}" }
        return attributes.keys.sorted().map { key in
            "\(key)=\(eventValueDescription(attributes[key]))"
        }.joined(separator: ",")
    }

    private static func eventValueDescription(_ value: PlayerEventValue?) -> String {
        switch value {
        case .some(.string(let value)):
            return value
        case .some(.int(let value)):
            return String(value)
        case .some(.uint(let value)):
            return String(value)
        case .some(.double(let value)):
            return String(value)
        case .some(.bool(let value)):
            return String(value)
        case nil:
            return "nil"
        }
    }
}

struct PlayerStartupDiagnostics {
    var playerInitAtMs: Double?
    var playRequestedAtMs: Double?
    var playbackStartedAtMs: Double?
    var playbackEndedAtMs: Double?
    var playbackStartedByKind: String?
    private var tracks: [TrackStartupDiagnostics] = []

    var initToPlayRequestMs: Double? {
        elapsed(from: playerInitAtMs, to: playRequestedAtMs)
    }

    var playRequestToPlaybackStartMs: Double? {
        elapsed(from: playRequestedAtMs, to: playbackStartedAtMs)
    }

    var orderedTracks: [TrackStartupDiagnostics] {
        tracks
    }

    mutating func record(_ event: PlayerEvent) {
        switch event.name {
        case .playerInit:
            playerInitAtMs = playerInitAtMs ?? event.timestampMs
        case .playbackRequest:
            playRequestedAtMs = event.timestampMs
            playbackStartedAtMs = nil
            playbackEndedAtMs = nil
            playbackStartedByKind = nil
            tracks.removeAll()
        case .playbackStart:
            playbackStartedAtMs = playbackStartedAtMs ?? event.timestampMs
            playbackStartedByKind = event.string("kind") ?? playbackStartedByKind
        case .playbackEnd:
            playbackEndedAtMs = event.timestampMs
        case .trackSubscribeStart:
            startTrack(event)
        case .trackReady:
            updateTrack(event) { track in
                track.trackName = event.string("trackName") ?? track.trackName
                track.readyAtMs = track.readyAtMs ?? event.timestampMs
                track.trackEpoch = event.uint("trackEpoch") ?? track.trackEpoch
            }
        case .trackPlaying:
            updateTrack(event) { track in
                track.trackName = event.string("trackName") ?? track.trackName
                track.playingAtMs = track.playingAtMs ?? event.timestampMs
                track.trackEpoch = event.uint("trackEpoch") ?? track.trackEpoch
            }
        case .trackSubscribeError:
            updateTrack(event) { track in
                track.trackName = event.string("trackName") ?? track.trackName
                track.errorAtMs = event.timestampMs
                track.errorMessage = event.string("message")
                track.trackEpoch = event.uint("trackEpoch") ?? track.trackEpoch
            }
        case .trackSubscribeEnd:
            updateTrack(event) { track in
                track.trackName = event.string("trackName") ?? track.trackName
                track.endedAtMs = event.timestampMs
                track.trackEpoch = event.uint("trackEpoch") ?? track.trackEpoch
            }
        case .trackSwitch:
            updateTrack(event) { track in
                track.trackName = event.string("trackName") ?? track.trackName
                track.activeAtMs = track.activeAtMs ?? event.timestampMs
                track.trackEpoch = event.uint("trackEpoch") ?? track.trackEpoch
            }
        default:
            break
        }
    }

    func elapsed(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }

    private mutating func startTrack(_ event: PlayerEvent) {
        guard let kind = event.string("kind") else { return }
        var track = TrackStartupDiagnostics(id: "track-\(event.sequence)", kind: kind)
        track.trackName = event.string("trackName")
        track.subscribeStartedAtMs = event.timestampMs
        track.trackEpoch = event.uint("trackEpoch") ?? 1
        tracks.append(track)
    }

    private mutating func updateTrack(
        _ event: PlayerEvent,
        _ update: (inout TrackStartupDiagnostics) -> Void
    ) {
        guard let kind = event.string("kind") else { return }
        let trackName = event.string("trackName")
        let trackEpoch = event.uint("trackEpoch")

        if let index = tracks.indices.reversed().first(where: { index in
            let track = tracks[index]
            guard track.kind == kind else { return false }
            if let trackName, let existingName = track.trackName, existingName != trackName {
                return false
            }
            if let trackEpoch, track.trackEpoch != trackEpoch {
                return false
            }
            return true
        }) {
            update(&tracks[index])
            return
        }

        var track = TrackStartupDiagnostics(id: "track-\(event.sequence)", kind: kind)
        track.trackEpoch = trackEpoch ?? 1
        update(&track)
        tracks.append(track)
    }
}

struct TrackStartupDiagnostics: Identifiable {
    let id: String
    let kind: String
    var trackName: String?
    var subscribeStartedAtMs: Double?
    var readyAtMs: Double?
    var playingAtMs: Double?
    var activeAtMs: Double?
    var errorAtMs: Double?
    var errorMessage: String?
    var endedAtMs: Double?
    var trackEpoch: UInt64 = 1

    var isTrackSwitch: Bool {
        trackEpoch > 1
    }

    var operationLabel: String {
        isTrackSwitch ? "Switch" : "Play request"
    }

    func subscribeToReadyMs() -> Double? {
        elapsed(from: subscribeStartedAtMs, to: readyAtMs)
    }

    func operationToReadyMs(playRequestedAtMs: Double?) -> Double? {
        elapsed(from: operationStartedAtMs(playRequestedAtMs: playRequestedAtMs), to: readyAtMs)
    }

    func readyToPlayingMs() -> Double? {
        elapsed(from: readyAtMs, to: playingAtMs)
    }

    func operationToPlayingMs(playRequestedAtMs: Double?) -> Double? {
        elapsed(from: operationStartedAtMs(playRequestedAtMs: playRequestedAtMs), to: playingAtMs)
    }

    func operationToActiveMs(playRequestedAtMs: Double?) -> Double? {
        elapsed(from: operationStartedAtMs(playRequestedAtMs: playRequestedAtMs), to: activeAtMs)
    }

    private func operationStartedAtMs(playRequestedAtMs: Double?) -> Double? {
        isTrackSwitch ? subscribeStartedAtMs : playRequestedAtMs
    }

    private func elapsed(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }
}
