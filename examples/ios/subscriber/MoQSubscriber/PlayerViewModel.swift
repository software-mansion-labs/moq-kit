import MoQKit
import SwiftUI

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    @Published var info: MoQBroadcastInfo
    @Published var player: MoQAVPlayer?
    @Published var offline: Bool = false
    @Published var isPlaying: Bool = false

    var eventTask: Task<Void, Never>?

    init(info: MoQBroadcastInfo) {
        self.id = info.path
        self.info = info
    }

    func observeEvents(of player: MoQAVPlayer) {
        eventTask = Task {
            for await event in player.events {
                switch event {
                case .trackPlaying:
                    isPlaying = true
                case .allTracksStopped:
                    isPlaying = false
                    offline = true
                default:
                    break
                }
            }
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await player?.stopAll()
        player = nil
        isPlaying = false
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var sessionState: MoQSessionState = .idle
    @Published var broadcasts: [BroadcastEntry] = []

    private var session: MoQSession?
    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?

    var canConnect: Bool {
        sessionState == .idle
    }

    var canStop: Bool {
        sessionState == .connecting || sessionState == .connected
    }
    
    var canPause: Bool {
        true
    }
    
    var canResume: Bool {
        true
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

    func connect(url: String) {
        let s = MoQSession(url: url)
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
                    let entry: BroadcastEntry
                    if let existing = broadcasts.first(where: { $0.id == info.path }) {
                        entry = existing
                        entry.info = info
                        entry.offline = false
                        await entry.stop()
                    } else {
                        entry = BroadcastEntry(info: info)
                        broadcasts.append(entry)
                    }
                    var tracks: [any MoQTrackInfo] = []
                    if let v = info.videoTracks.first { tracks.append(v) }
                    if let a = info.audioTracks.first { tracks.append(a) }
                    let p = try? MoQAVPlayer(tracks: tracks, maxLatencyMs: 500)
                    entry.player = p
                    if let p {
                        entry.observeEvents(of: p)
                    }
                    try? await p?.play()
                case .unavailable(let path):
                    if let entry = broadcasts.first(where: { $0.id == path }) {
                        await entry.stop()
                        entry.offline = true
                    }
                }
            }
        }

        Task {
            do {
                try await s.connect()
            } catch {}
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
    
    func pause() {
        broadcasts.forEach { entry in
            Task {
                await entry.player?.pause()
            }
        }
    }
    
    func play() {
        broadcasts.forEach { entry in
            Task {
                do {
                    try await entry.player?.play()
                } catch {}
            }
        }
    }
}
