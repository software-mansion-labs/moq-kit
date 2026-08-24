import MoQKit

extension PlayerEventType {
    var logTrackName: String? {
        switch self {
        case .playbackStart(let event), .trackPlaying(let event):
            event.track.trackName ?? "none"
        case .trackReady(let event):
            event.track.trackName ?? "none"
        case .trackSubscribeError(let event), .decodeError(let event):
            event.track.trackName ?? "none"
        case .trackSubscribeStart(let track),
             .trackSubscribeEnd(let track),
             .trackSwitch(let track),
             .trackStallStart(let track),
             .trackStallEnd(let track),
             .rebufferStart(let track),
             .rebufferEnd(let track):
            track.trackName ?? "none"
        case .trackSelect(let selection):
            selection.trackName ?? "none"
        case .playerInit,
             .playerDestroy,
             .playbackRequest,
             .playbackPause,
             .playbackResume,
             .playbackEnd:
            nil
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
