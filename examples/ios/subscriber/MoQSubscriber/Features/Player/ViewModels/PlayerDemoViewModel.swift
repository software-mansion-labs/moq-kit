import MoQKit
import SwiftUI

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
        case .error(let msg): return "error: \(msg)"
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
        stop()
        self.targetLatencyMs = targetLatencyMs
        let s = Session(url: url)
        session = s

        stateObserverTask = Task {
            for await state in s.state {
                sessionState = state
            }
        }

        Task {
            do {
                try await s.connect()
                let subscription = try await s.subscribe(prefix: prefix)
                self.subscription = subscription
                broadcastObserverTask = Task { [weak self] in
                    guard let self else { return }
                    for await broadcast in subscription.broadcasts {
                        self.observeCatalogs(for: broadcast)
                    }
                }
            } catch {
                sessionState = .error(error.localizedDescription)
            }
        }
    }

    func stop() {
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
                await entry.stop()
            }
            subscription?.cancel()
            await s?.close()
        }
    }

    private func observeCatalogs(for broadcast: Broadcast) {
        catalogObserverTasks[broadcast.path]?.cancel()
        catalogObserverTasks[broadcast.path] = Task { [weak self] in
            guard let self else { return }

            for await catalog in broadcast.catalogs() {
                await self.replaceBroadcast(with: catalog)
            }

            guard !Task.isCancelled else { return }
            await self.markBroadcastUnavailable(path: broadcast.path)
            self.catalogObserverTasks.removeValue(forKey: broadcast.path)
        }
    }

    private func replaceBroadcast(with catalog: Catalog) async {
        let existingEntries = broadcasts.filter { $0.broadcastPath == catalog.path }
        for entry in existingEntries {
            await entry.stop()
        }
        broadcasts.removeAll { $0.broadcastPath == catalog.path }

        let selectedTracks = preferredTracks(for: catalog)
        guard selectedTracks.videoTrackName != nil || selectedTracks.audioTrackName != nil else {
            return
        }

        let entry = BroadcastEntry(
            catalog: catalog,
            initialVideoTrackName: selectedTracks.videoTrackName,
            initialLatencyMs: targetLatencyMs
        )
        broadcasts.append(entry)

        guard let player = try? Player(
            catalog: catalog,
            videoTrackName: selectedTracks.videoTrackName,
            audioTrackName: selectedTracks.audioTrackName,
            targetBufferingMs: targetLatencyMs
        ) else {
            entry.offline = true
            return
        }

        entry.attach(player: player)
        try? await player.play()
    }

    private func markBroadcastUnavailable(path: String) async {
        let matchingEntries = broadcasts.filter { $0.broadcastPath == path }
        for entry in matchingEntries {
            await entry.stop()
            entry.offline = true
        }
    }

    private func preferredTracks(
        for catalog: Catalog
    ) -> (videoTrackName: String?, audioTrackName: String?) {
        let audioTrackName = catalog.audioTracks.first?.name
        let highestVideoTrackName = catalog.videoTracks.max(by: isLowerQualityVideoTrack)?.name
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
}
