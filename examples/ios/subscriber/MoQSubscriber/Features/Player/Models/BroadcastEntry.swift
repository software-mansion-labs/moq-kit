import AVFoundation
import MoQKit

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    let broadcastPath: String

    @Published var selectedVideoTrack: MoQVideoTrackInfo?
    @Published var info: MoQBroadcastInfo
    @Published var player: MoQPlayer?
    @Published var offline = false
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var playbackStats: PlaybackStats?
    @Published var targetLatencyMs: Double

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer
    }

    private var eventTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var pendingVideoTrack: MoQVideoTrackInfo?

    init(info: MoQBroadcastInfo, initialVideoTrack: MoQVideoTrackInfo?, initialLatencyMs: UInt64) {
        self.id = info.path
        self.broadcastPath = info.path
        self.selectedVideoTrack = initialVideoTrack
        self.info = info
        self.targetLatencyMs = Double(initialLatencyMs)
    }

    func attach(player: MoQPlayer) {
        self.player = player
        observeEvents(of: player.events)
    }

    func switchVideoTrack(to track: MoQVideoTrackInfo) {
        pendingVideoTrack = track
        Task { try? await player?.switchTrack(to: track) }
    }

    func updateTargetLatency(ms: UInt64) {
        targetLatencyMs = Double(ms)
        player?.updateTargetLatency(ms: ms)
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopStatsPolling()
        await player?.stopAll()
        player = nil
        isPlaying = false
    }

    private func observeEvents(of events: AsyncStream<MoQPlayerEvent>) {
        eventTask?.cancel()
        eventTask = Task {
            for await event in events {
                switch event {
                case .trackPlaying:
                    isPlaying = true
                    startStatsPolling()
                case .trackSwitched(.video):
                    if let pendingVideoTrack {
                        selectedVideoTrack = pendingVideoTrack
                        self.pendingVideoTrack = nil
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
                playbackStats = player?.stats
            }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
        playbackStats = nil
    }
}
