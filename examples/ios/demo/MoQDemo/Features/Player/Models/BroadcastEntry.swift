import AVFoundation
import MoQKit

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    let broadcastPath: String

    @Published var selectedVideoTrackName: String?
    @Published var catalog: Catalog
    @Published var player: Player?
    @Published var offline = false
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var playbackStats: PlaybackStats?
    @Published var targetLatencyMs: Double
    @Published var volume: Double = 1.0

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer
    }

    var hasAudio: Bool {
        !catalog.audioTracks.isEmpty
    }

    private var eventTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var pendingVideoTrackName: String?
    private var lastNonZeroVolume: Double = 1.0

    var selectedVideoTrack: VideoTrackInfo? {
        guard let selectedVideoTrackName else { return nil }
        return catalog.videoTracks.first(where: { $0.name == selectedVideoTrackName })
    }

    init(catalog: Catalog, initialVideoTrackName: String?, initialLatencyMs: UInt64) {
        self.id = catalog.path
        self.broadcastPath = catalog.path
        self.selectedVideoTrackName = initialVideoTrackName
        self.catalog = catalog
        self.targetLatencyMs = Double(initialLatencyMs)
    }

    func attach(player: Player) {
        self.player = player
        observeEvents(of: player.events)
    }

    func switchVideoTrack(to trackName: String) {
        pendingVideoTrackName = trackName
        Task { try? await player?.switchTrack(to: trackName) }
    }

    func updateTargetLatency(ms: UInt64) {
        targetLatencyMs = Double(ms)
        player?.updateTargetLatency(ms: ms)
    }

    func updateVolume(_ newVolume: Double) {
        let clampedVolume = min(max(newVolume, 0), 1)
        volume = clampedVolume
        if clampedVolume > 0 {
            lastNonZeroVolume = clampedVolume
        }
        player?.setVolume(Float(clampedVolume))
    }

    func toggleMute() {
        if volume > 0 {
            updateVolume(0)
        } else {
            updateVolume(lastNonZeroVolume)
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopStatsPolling()
        await player?.stopAll()
        player = nil
        isPlaying = false
    }

    private func observeEvents(of events: AsyncStream<PlayerEvent>) {
        eventTask?.cancel()
        eventTask = Task {
            for await event in events {
                switch event {
                case .trackPlaying:
                    isPlaying = true
                    startStatsPolling()
                case .trackSwitched(.video):
                    if let pendingVideoTrackName {
                        selectedVideoTrackName = pendingVideoTrackName
                        self.pendingVideoTrackName = nil
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
