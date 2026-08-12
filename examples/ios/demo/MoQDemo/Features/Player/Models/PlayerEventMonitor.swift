import Combine
import MoQKit
import os

@MainActor
final class PlayerEventMonitor: ObservableObject {
    typealias ActiveTrackNames = (video: String?, audio: String?)

    @Published private(set) var startupDiagnostics = PlayerStartupDiagnostics()
    @Published private(set) var playbackStats: PlaybackStats?

    private let broadcastPath: String
    private weak var player: Player?
    private var eventsSubscription: PlayerEventSubscription?
    private var statsSubscription: PlayerEventSubscription?

    init(broadcastPath: String) {
        self.broadcastPath = broadcastPath
    }

    func attach(
        to player: Player,
        activeTrackNames: @escaping @MainActor @Sendable () -> ActiveTrackNames,
        onEvent: @escaping @MainActor @Sendable (PlayerEvent) -> Void
    ) {
        detach()
        self.player = player
        eventsSubscription = player.subscribeEvents { [weak self] event in
            guard let self else { return }

            let activeTrackNames = activeTrackNames()
            self.handleEvent(
                event,
                activeVideoTrackName: activeTrackNames.video,
                activeAudioTrackName: activeTrackNames.audio
            )
            onEvent(event)
        }
    }

    func detach() {
        eventsSubscription?.cancel()
        eventsSubscription = nil
        cancelStatsSubscription()
        player = nil
    }

    private func handleEvent(
        _ event: PlayerEvent,
        activeVideoTrackName: String?,
        activeAudioTrackName: String?
    ) {
        if let trackName = event.type.logTrackName {
            broadcastEntryLogger.debug(
                "Player event path=\(self.broadcastPath), event=\(event.name.rawValue), track=\(trackName)"
            )
        } else {
            broadcastEntryLogger.debug(
                "Player event path=\(self.broadcastPath), event=\(event.name.rawValue)"
            )
        }

        startupDiagnostics.record(
            event,
            activeVideoTrackName: activeVideoTrackName,
            activeAudioTrackName: activeAudioTrackName
        )

        switch event.type {
        case .playbackStart:
            startStatsSubscription()
        case .playbackEnd:
            cancelStatsSubscription()
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

    private func cancelStatsSubscription() {
        statsSubscription?.cancel()
        statsSubscription = nil
        playbackStats = nil
    }
}
