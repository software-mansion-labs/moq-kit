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
    @Published var connectionStats: ConnectionStats?
    @Published var broadcasts: [BroadcastEntry] = []
    @Published private(set) var selectedBroadcastPath: String?

    private var session: Session?
    private var subscription: BroadcastSubscription?
    private var targetLatencyMs: UInt64 = 200
    private var stateObserverTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionStatsTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var catalogObserverTasks: [String: Task<Void, Never>] = [:]

    var selectedBroadcast: BroadcastEntry? {
        guard let selectedBroadcastPath else { return nil }
        return broadcasts.first(where: { $0.id == selectedBroadcastPath })
    }

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

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await s.connect()
                guard !Task.isCancelled, session === s else {
                    await s.close()
                    return
                }
                let subscription = try await s.subscribe(prefix: prefix)
                self.subscription = subscription
                playerDemoLogger.debug("Subscribed to broadcasts prefix=\(prefix)")
                connectionStatsTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let stats = await s.connectionStats() else {
                            self?.connectionStats = nil
                            return
                        }
                        guard !Task.isCancelled else { return }
                        if self?.connectionStats != stats {
                            self?.connectionStats = stats
                        }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                broadcastObserverTask = Task { [weak self] in
                    guard let self else { return }
                    for await broadcast in subscription.broadcasts {
                        playerDemoLogger.debug("Broadcast announced path=\(broadcast.path)")
                        self.observeCatalogs(for: broadcast)
                    }
                }
            } catch {
                guard !Task.isCancelled, session === s else {
                    await s.close()
                    return
                }
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
        connectionTask?.cancel()
        connectionTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        connectionStatsTask?.cancel()
        connectionStatsTask = nil
        broadcastObserverTask?.cancel()
        broadcastObserverTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        for (_, task) in catalogObserverTasks {
            task.cancel()
        }
        catalogObserverTasks.removeAll()
        let entries = broadcasts
        broadcasts = []
        selectedBroadcastPath = nil
        connectionStats = nil
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

    func selectBroadcast(path: String) {
        guard let entry = broadcasts.first(where: { $0.id == path }), !entry.offline else {
            return
        }
        if selectedBroadcastPath == path, entry.player != nil {
            return
        }

        selectionTask?.cancel()
        selectedBroadcastPath = path
        selectionTask = Task { [weak self] in
            guard let self else { return }
            for playingEntry in broadcasts where playingEntry.player != nil {
                await playingEntry.stop(reason: "selected broadcast changed to \(path)")
                guard !Task.isCancelled, selectedBroadcastPath == path else { return }
            }
            guard
                !Task.isCancelled,
                selectedBroadcastPath == path,
                let selectedEntry = broadcasts.first(where: { $0.id == path })
            else { return }
            await startPlayer(selectedEntry)
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
                await self.applyCatalogUpdate(catalog)
            }

            guard !Task.isCancelled else { return }
            playerDemoLogger.debug("Catalog stream ended path=\(broadcast.path)")
            await self.markBroadcastUnavailable(path: broadcast.path)
            self.catalogObserverTasks.removeValue(forKey: broadcast.path)
        }
    }

    private func applyCatalogUpdate(_ catalog: Catalog) async {
        let existingEntry = broadcasts.first(where: { $0.broadcastPath == catalog.path })
        let action = existingEntry == nil ? "add" : "refresh"
        playerDemoLogger.debug(
            "Applying catalog path=\(catalog.path), action=\(action), \(self.catalogLogDescription(catalog))"
        )

        let trackPreferences = preferredTracks(
            for: catalog,
            preferredVideoTrackName: existingEntry?.selectedVideoTrackName,
            preferredAudioTrackName: existingEntry?.selectedAudioTrackName
        )
        playerDemoLogger.debug(
            "Preferred tracks for path=\(catalog.path): video=\(trackPreferences.videoTrackName ?? "none"), audio=\(trackPreferences.audioTrackName ?? "none")"
        )
        guard trackPreferences.videoTrackName != nil || trackPreferences.audioTrackName != nil else {
            playerDemoLogger.warning("No playable tracks for path=\(catalog.path)")
            if let existingEntry {
                await existingEntry.stop(reason: "catalog has no playable tracks for \(catalog.path)")
                broadcasts.removeAll { $0.id == existingEntry.id }
            }
            return
        }

        if let existingEntry {
            let wasSelected = selectedBroadcastPath == existingEntry.id
            await existingEntry.stop(reason: "catalog metadata refreshed for \(catalog.path)")
            existingEntry.catalog = catalog
            existingEntry.selectedVideoTrackName = trackPreferences.videoTrackName
            existingEntry.selectedAudioTrackName = trackPreferences.audioTrackName
            existingEntry.offline = false
            if wasSelected {
                await startPlayer(existingEntry)
            }
            return
        }

        let newEntry = BroadcastEntry(
            catalog: catalog,
            initialVideoTrackName: trackPreferences.videoTrackName,
            initialAudioTrackName: trackPreferences.audioTrackName,
            initialLatencyMs: targetLatencyMs
        )
        broadcasts.append(newEntry)
        broadcasts.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        if selectedBroadcastPath == newEntry.id {
            await startPlayer(newEntry)
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

    private func startPlayer(_ entry: BroadcastEntry) async {
        guard selectedBroadcastPath == entry.id, entry.player == nil, !entry.offline else { return }

        let selectedTracks = preferredTracks(
            for: entry.catalog,
            preferredVideoTrackName: entry.selectedVideoTrackName,
            preferredAudioTrackName: entry.selectedAudioTrackName
        )
        guard selectedTracks.videoTrackName != nil || selectedTracks.audioTrackName != nil else {
            return
        }

        guard
            let player = try? Player(
                catalog: entry.catalog,
                videoTrackName: selectedTracks.videoTrackName,
                audioTrackName: selectedTracks.audioTrackName,
                targetBuffering: .milliseconds(
                    Int64(min(UInt64(entry.targetLatencyMs), UInt64(Int64.max)))
                ),
                volume: Float(entry.volume)
            )
        else {
            playerDemoLogger.error("Failed to create Player for path=\(entry.id)")
            entry.offline = true
            return
        }

        entry.selectedVideoTrackName = selectedTracks.videoTrackName
        entry.selectedAudioTrackName = selectedTracks.audioTrackName
        entry.attach(player: player)
        do {
            try await player.play()
            guard !Task.isCancelled, selectedBroadcastPath == entry.id else {
                await entry.stop(reason: "broadcast selection changed while starting \(entry.id)")
                return
            }
        } catch {
            guard !Task.isCancelled, selectedBroadcastPath == entry.id else {
                await entry.stop(reason: "broadcast selection changed while starting \(entry.id)")
                return
            }
            playerDemoLogger.error(
                "Failed to start Player for path=\(entry.id): \(error.localizedDescription)"
            )
            await entry.stop(reason: "player failed to start for \(entry.id)")
            entry.offline = true
        }
    }

    private func preferredTracks(
        for catalog: Catalog,
        preferredVideoTrackName: String? = nil,
        preferredAudioTrackName: String? = nil
    ) -> (videoTrackName: String?, audioTrackName: String?) {
        let audioTrackName = catalog.playableAudioTracks.first {
            $0.name == preferredAudioTrackName
        }?.name ?? catalog.playableAudioTracks.first?.name
        let videoTrackName = catalog.playableVideoTracks.first {
            $0.name == preferredVideoTrackName
        }?.name ?? catalog.playableVideoTracks.max(by: isLowerQualityVideoTrack)?.name
        return (videoTrackName, audioTrackName)
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
