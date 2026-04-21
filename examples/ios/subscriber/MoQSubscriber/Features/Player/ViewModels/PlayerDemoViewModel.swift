import MoQKit
import SwiftUI

@MainActor
final class PlayerDemoViewModel: ObservableObject {
    @Published var sessionState: SessionState = .idle
    @Published var broadcasts: [BroadcastEntry] = []

    private var session: Session?
    private var targetLatencyMs: UInt64 = 200
    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?

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

        broadcastObserverTask = Task {
            for await event in s.broadcasts {
                switch event {
                case .available(let info):
                    await replaceBroadcast(with: info)

                case .unavailable(let path):
                    await markBroadcastUnavailable(path: path)
                }
            }
        }

        Task {
            do {
                try await s.connect()
                try s.subscribe(prefix: prefix)
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
        let entries = broadcasts
        broadcasts = []
        sessionState = .idle
        let s = session
        session = nil
        Task {
            for entry in entries {
                await entry.stop()
            }
            await s?.close()
        }
    }

    private func replaceBroadcast(with info: BroadcastInfo) async {
        let existingEntries = broadcasts.filter { $0.broadcastPath == info.path }
        for entry in existingEntries {
            await entry.stop()
        }
        broadcasts.removeAll { $0.broadcastPath == info.path }

        let selectedTracks = preferredTracks(for: info)
        guard !selectedTracks.tracks.isEmpty else { return }

        let entry = BroadcastEntry(
            info: info,
            initialVideoTrack: selectedTracks.videoTrack,
            initialLatencyMs: targetLatencyMs
        )
        broadcasts.append(entry)

        guard let player = try? Player(
            tracks: selectedTracks.tracks,
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
        for info: BroadcastInfo
    ) -> (videoTrack: VideoTrackInfo?, tracks: [any TrackInfo]) {
        let audioTrack = info.audioTracks.first
        let highestVideoTrack = info.videoTracks.max(by: isLowerQualityVideoTrack)

        var tracks: [any TrackInfo] = []
        if let highestVideoTrack {
            tracks.append(highestVideoTrack)
        }
        if let audioTrack {
            tracks.append(audioTrack)
        }

        return (highestVideoTrack, tracks)
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
