import MoQKit
import SwiftUI
import os

private let playerDemoLogger = Logger(
    subsystem: "com.swmansion.MoQDemo",
    category: "player-demo"
)

@MainActor
final class PlayerDemoViewModel: ObservableObject {
    @Published var sessionState: SessionState = .idle
    @Published var broadcasts: [BroadcastEntry] = []

    private var session: Session?
    private var subscription: BroadcastSubscription?
    private var targetLatencyMs: UInt64 = 200
    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?
    private var catalogObserverTasks: [String: Task<Void, Never>] = [:]

    var canConnect: Bool {
        switch sessionState {
        case .idle, .error:
            return true
        default:
            return false
        }
    }

    var canStop: Bool {
        sessionState == .connecting || sessionState == .connected
    }

    var stateLabel: String {
        switch sessionState {
        case .idle: return "idle"
        case .connecting: return "connecting..."
        case .connected: return "connected"
        case .error(let error): return "error: \(error.localizedDescription)"
        case .closed: return "closed"
        }
    }

    var stateColor: Color {
        switch sessionState {
        case .idle: return .gray
        case .connecting: return .orange
        case .connected: return .blue
        case .error: return .red
        case .closed: return .gray
        }
    }

    func connect(url: String, prefix: String, targetLatencyMs: UInt64 = 200) {
        playerDemoLogger.debug(
            "Connect requested url=\(url), prefix=\(prefix), targetLatencyMs=\(targetLatencyMs)"
        )
        stop(reason: "connect requested before opening new session")
        self.targetLatencyMs = targetLatencyMs
        let s = Session(url: url)
        session = s

        stateObserverTask = Task {
            for await state in s.state {
                playerDemoLogger.debug("Session state update: \(self.stateLabel) -> \(String(describing: state))")
                sessionState = state
            }
        }

        Task {
            do {
                try await s.connect()
                let subscription = try await s.subscribe(prefix: prefix)
                self.subscription = subscription
                playerDemoLogger.debug("Subscribed to broadcasts prefix=\(prefix)")
                broadcastObserverTask = Task { [weak self] in
                    guard let self else { return }
                    for await broadcast in subscription.broadcasts {
                        playerDemoLogger.debug("Broadcast announced path=\(broadcast.path)")
                        self.observeCatalogs(for: broadcast)
                    }
                }
            } catch {
                playerDemoLogger.error("Connect failed: \(error.localizedDescription)")
                let sessionError =
                    error as? SessionError ?? .connectionFailed(error.localizedDescription)
                sessionState = .error(sessionError)
            }
        }
    }

    func stop(reason: String = "user requested stop") {
        playerDemoLogger.debug(
            "Stop requested reason=\(reason), state=\(self.stateLabel), broadcasts=\(self.broadcasts.count), hasSession=\(self.session != nil), hasSubscription=\(self.subscription != nil)"
        )
        stateObserverTask?.cancel()
        stateObserverTask = nil
        broadcastObserverTask?.cancel()
        broadcastObserverTask = nil
        for (_, task) in catalogObserverTasks {
            task.cancel()
        }
        catalogObserverTasks.removeAll()
        let entries = broadcasts
        broadcasts = []
        sessionState = .idle
        let s = session
        session = nil
        let subscription = subscription
        self.subscription = nil
        Task {
            for entry in entries {
                await entry.stop(reason: "PlayerDemoViewModel.stop(\(reason))")
            }
            subscription?.cancel()
            await s?.close()
        }
    }

    private func observeCatalogs(for broadcast: Broadcast) {
        playerDemoLogger.debug("Starting catalog observer path=\(broadcast.path)")
        catalogObserverTasks[broadcast.path]?.cancel()
        catalogObserverTasks[broadcast.path] = Task { [weak self] in
            guard let self else { return }

            for await catalog in broadcast.catalogs() {
                playerDemoLogger.debug(
                    "Catalog update path=\(catalog.path), \(self.catalogLogDescription(catalog))"
                )
                await self.replaceBroadcast(with: catalog)
            }

            guard !Task.isCancelled else { return }
            playerDemoLogger.debug("Catalog stream ended path=\(broadcast.path)")
            await self.markBroadcastUnavailable(path: broadcast.path)
            self.catalogObserverTasks.removeValue(forKey: broadcast.path)
        }
    }

    private func replaceBroadcast(with catalog: Catalog) async {
        let existingEntries = broadcasts.filter { $0.broadcastPath == catalog.path }
        playerDemoLogger.debug(
            "Replacing broadcast path=\(catalog.path), existingEntries=\(existingEntries.count), \(self.catalogLogDescription(catalog))"
        )
        for entry in existingEntries {
            await entry.stop(reason: "catalog update replaced broadcast \(catalog.path)")
        }
        broadcasts.removeAll { $0.broadcastPath == catalog.path }

        let selectedTracks = preferredTracks(for: catalog)
        playerDemoLogger.debug(
            "Selected tracks for path=\(catalog.path): video=\(selectedTracks.videoTrackName ?? "none"), audio=\(selectedTracks.audioTrackName ?? "none")"
        )
        guard selectedTracks.videoTrackName != nil || selectedTracks.audioTrackName != nil else {
            playerDemoLogger.warning("No playable tracks for path=\(catalog.path)")
            return
        }

        let entry = BroadcastEntry(
            catalog: catalog,
            initialVideoTrackName: selectedTracks.videoTrackName,
            initialAudioTrackName: selectedTracks.audioTrackName,
            initialLatencyMs: targetLatencyMs
        )
        broadcasts.append(entry)

        guard
            let player = try? Player(
                catalog: catalog,
                videoTrackName: selectedTracks.videoTrackName,
                audioTrackName: selectedTracks.audioTrackName,
                targetBuffering: .milliseconds(Int64(min(targetLatencyMs, UInt64(Int64.max)))),
                volume: Float(entry.volume)
            )
        else {
            playerDemoLogger.error("Failed to create Player for path=\(catalog.path)")
            entry.offline = true
            return
        }

        entry.attach(player: player)
        do {
            try await player.play()
        } catch {
            playerDemoLogger.error("Failed to start Player for path=\(catalog.path): \(error.localizedDescription)")
            entry.offline = true
        }
    }

    private func markBroadcastUnavailable(path: String) async {
        let matchingEntries = broadcasts.filter { $0.broadcastPath == path }
        playerDemoLogger.debug(
            "Marking broadcast unavailable path=\(path), matchingEntries=\(matchingEntries.count)"
        )
        for entry in matchingEntries {
            await entry.stop(reason: "catalog stream ended for \(path)")
            entry.offline = true
        }
    }

    private func preferredTracks(
        for catalog: Catalog
    ) -> (videoTrackName: String?, audioTrackName: String?) {
        let audioTrackName = catalog.playableAudioTracks.first?.name
        let highestVideoTrackName = catalog.playableVideoTracks.max(by: isLowerQualityVideoTrack)?
            .name
        return (highestVideoTrackName, audioTrackName)
    }

    private func isLowerQualityVideoTrack(
        _ lhs: VideoTrackInfo,
        _ rhs: VideoTrackInfo
    ) -> Bool {
        codedPixelCount(for: lhs) < codedPixelCount(for: rhs)
    }

    private func codedPixelCount(for track: VideoTrackInfo) -> UInt64 {
        guard let coded = track.config.coded else { return 0 }
        return UInt64(coded.width) * UInt64(coded.height)
    }

    private func catalogLogDescription(_ catalog: Catalog) -> String {
        let videoTracks = catalog.playableVideoTracks
            .map { track in
                let coded = track.config.coded.map { "\($0.width)x\($0.height)" } ?? "unknown-size"
                return "\(track.name):\(track.config.codec):\(coded)"
            }
            .joined(separator: ",")
        let audioTracks = catalog.playableAudioTracks
            .map { "\($0.name):\($0.config.codec):\($0.config.sampleRate)Hz" }
            .joined(separator: ",")
        return "playableVideo=[\(videoTracks)], playableAudio=[\(audioTracks)]"
    }
}
