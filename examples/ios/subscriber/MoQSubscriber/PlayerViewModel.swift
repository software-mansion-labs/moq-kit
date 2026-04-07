import AVFoundation
import MoQKit
import SwiftUI

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    let broadcastPath: String
    @Published var selectedVideoTrack: MoQVideoTrackInfo?
    @Published var info: MoQBroadcastInfo
    @Published var player: MoQPlayer?
    @Published var offline: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false
    @Published var playbackStats: PlaybackStats?
    @Published var targetLatencyMs: Double

    var eventTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var pendingVideoTrack: MoQVideoTrackInfo?

    init(info: MoQBroadcastInfo, initialVideoTrack: MoQVideoTrackInfo?, initialLatencyMs: UInt64) {
        self.id = info.path
        self.broadcastPath = info.path
        self.selectedVideoTrack = initialVideoTrack
        self.info = info
        self.targetLatencyMs = Double(initialLatencyMs)
    }

    func switchVideoTrack(to track: MoQVideoTrackInfo) {
        pendingVideoTrack = track
        Task { try? await player?.switchTrack(to: track) }
    }

    func updateTargetLatency(ms: UInt64) {
        player?.updateTargetLatency(ms: ms)
    }

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer
    }

    func observeEvents(of events: AsyncStream<MoQPlayerEvent>) {
        eventTask = Task {
            for await event in events {
                switch event {
                case .trackPlaying:
                    isPlaying = true
                    startStatsPolling()
                case .trackSwitched(.video):
                    if let pending = pendingVideoTrack {
                        selectedVideoTrack = pending
                        pendingVideoTrack = nil
                    }
                case .allTracksStopped:
                    isPlaying = false
                    offline = true
                    stopStatsPolling()
                default:
                    break
                }
            }
        }
    }

    private func startStatsPolling() {
        guard statsTimer == nil else { return }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackStats = self.player?.stats
            }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
        playbackStats = nil
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopStatsPolling()
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

    func connect(url: String, targetLatencyMs: UInt64 = 200) {
        self.targetLatencyMs = targetLatencyMs
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
                    let existingEntries = broadcasts.filter { $0.broadcastPath == info.path }
                    for entry in existingEntries { await entry.stop() }
                    broadcasts.removeAll { $0.broadcastPath == info.path }

                    let audioTrack = info.audioTracks.first
                    let highestVideoTrack = info.videoTracks
                        .sorted {
                            ($0.config.coded.map { UInt64($0.width) * UInt64($0.height) } ?? 0)
                                > ($1.config.coded.map { UInt64($0.width) * UInt64($0.height) } ?? 0)
                        }
                        .first

                    var tracks: [any MoQTrackInfo] = []
                    if let v = highestVideoTrack { tracks.append(v) }
                    if let a = audioTrack { tracks.append(a) }
                    guard !tracks.isEmpty else { continue }

                    let entry = BroadcastEntry(
                        info: info,
                        initialVideoTrack: highestVideoTrack,
                        initialLatencyMs: self.targetLatencyMs
                    )
                    broadcasts.append(entry)

                    let p = try? MoQPlayer(tracks: tracks, targetBufferingMs: self.targetLatencyMs)
                    entry.player = p
                    if let p { entry.observeEvents(of: p.events) }
                    try? await p?.play()

                case .unavailable(let path):
                    let entries = broadcasts.filter { $0.broadcastPath == path }
                    for entry in entries {
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

}
