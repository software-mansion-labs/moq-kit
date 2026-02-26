import MoQKit
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var session: MoQSession?
    @Published var sessionState: MoQSessionState = .idle
    @Published var broadcastInfo: MoQBroadcastInfo?
    @Published var broadcastOffline = false

    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?

    var canConnect: Bool {
        sessionState == .idle
    }

    var canStop: Bool {
        sessionState == .connecting || sessionState == .connected || sessionState == .playing
    }

    var stateLabel: String {
        switch sessionState {
        case .idle: return "idle"
        case .connecting: return "connecting..."
        case .connected: return "connected"
        case .playing: return "playing"
        case .error(let msg): return "error: \(msg)"
        case .closed: return "closed"
        }
    }

    var stateColor: Color {
        switch sessionState {
        case .idle: return .gray
        case .connecting: return .orange
        case .connected: return .blue
        case .playing: return .green
        case .error: return .red
        case .closed: return .gray
        }
    }

    func connect(url: String, path: String) {
        let s = MoQSession(url: url, path: path)
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
                    broadcastInfo = info
                    broadcastOffline = false
                    try? await s.startTrack(videoIndex: info.videoTracks.first?.index, audioIndex: info.audioTracks.first?.index)
                case .unavailable:
                    broadcastOffline = true
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
        broadcastInfo = nil
        broadcastOffline = false
        let s = session
        session = nil
        sessionState = .idle
        Task { await s?.close() }
    }
}
