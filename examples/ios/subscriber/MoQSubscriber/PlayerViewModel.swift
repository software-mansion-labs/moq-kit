import AVFoundation
import MoQKit
import SwiftUI

enum PlayerType: String, CaseIterable {
    case realTime = "RealTime"
    case avPlayer = "AVPlayer"
}

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    @Published var info: MoQBroadcastInfo
    @Published var player: MoQAVPlayer?
    @Published var realTimePlayer: MoQRealTimePlayer?
    @Published var offline: Bool = false
    @Published var isPlaying: Bool = false
    @Published var audioLatencyMs: Double?
    @Published var videoLatencyMs: Double?

    var eventTask: Task<Void, Never>?
    private var latencyTimer: Timer?

    init(info: MoQBroadcastInfo) {
        self.id = info.path
        self.info = info
    }

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer ?? realTimePlayer?.videoLayer
    }

    func observeEvents(of events: AsyncStream<MoQPlayerEvent>) {
        eventTask = Task {
            for await event in events {
                switch event {
                case .trackPlaying:
                    isPlaying = true
                    startLatencyPolling()
                case .allTracksStopped:
                    isPlaying = false
                    offline = true
                    stopLatencyPolling()
                default:
                    break
                }
            }
        }
    }

    private func startLatencyPolling() {
        guard latencyTimer == nil else { return }
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let info = self.realTimePlayer?.latency
                self.audioLatencyMs = info?.audioMs
                self.videoLatencyMs = info?.videoMs
            }
        }
    }

    private func stopLatencyPolling() {
        latencyTimer?.invalidate()
        latencyTimer = nil
        audioLatencyMs = nil
        videoLatencyMs = nil
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopLatencyPolling()
        await player?.stopAll()
        player = nil
        await realTimePlayer?.stopAll()
        realTimePlayer = nil
        isPlaying = false
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var sessionState: MoQSessionState = .idle
    @Published var broadcasts: [BroadcastEntry] = []
    @Published var playerType: PlayerType = .realTime

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
                    // if let a = info.audioTracks.first { tracks.append(a) }

                    switch self.playerType {
                    case .avPlayer:
                        let p = try? MoQAVPlayer(tracks: tracks, maxLatencyMs: 500)
                        entry.player = p
                        if let p {
                            entry.observeEvents(of: p.events)
                        }
                        try? await p?.play()
                    case .realTime:
                        let p = try? MoQRealTimePlayer(tracks: tracks, targetBufferingMs: 100)
                        entry.realTimePlayer = p
                        if let p {
                            entry.observeEvents(of: p.events)
                        }
                        try? await p?.play()
                    }
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
                await entry.realTimePlayer?.pause()
            }
        }
    }

    func play() {
        broadcasts.forEach { entry in
            Task {
                do {
                    try await entry.player?.play()
                    try await entry.realTimePlayer?.play()
                } catch {}
            }
        }
    }
}
