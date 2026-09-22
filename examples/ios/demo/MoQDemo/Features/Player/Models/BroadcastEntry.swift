import AVFoundation
import Combine
import MoQKit
import os

let broadcastEntryLogger = Logger(
    subsystem: "com.swmansion.MoQDemo",
    category: "broadcast-entry"
)

@MainActor
final class BroadcastEntry: ObservableObject, Identifiable {
    let id: String
    let broadcastPath: String
    let audioAnalysis = BroadcastAudioAnalysis()

    @Published var selectedVideoTrackName: String?
    @Published var selectedAudioTrackName: String?
    @Published var catalog: Catalog
    @Published var player: Player?
    @Published var offline = false
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var targetLatencyMs: Double
    @Published var volume: Double = 1.0

    var playbackStats: PlaybackStats? {
        playerEventMonitor.playbackStats
    }

    var startupDiagnostics: PlayerStartupDiagnostics {
        playerEventMonitor.startupDiagnostics
    }

    var dvrPlayer: DVR.Player? {
        dvrPlaybackController.player
    }

    var isDVRPresented: Bool {
        get { dvrPlaybackController.isPresented }
        set { dvrPlaybackController.setPresented(newValue) }
    }

    var isDVRLoading: Bool {
        dvrPlaybackController.isLoading
    }

    var isDVRAvailable: Bool {
        dvrPlaybackController.isAvailable
    }

    var dvrError: String? {
        dvrPlaybackController.error
    }

    var videoLayer: AVSampleBufferDisplayLayer? {
        player?.videoLayer
    }

    var hasAudio: Bool {
        selectedAudioTrack != nil
    }

    var selectedVideoTrack: VideoTrackInfo? {
        guard let selectedVideoTrackName else { return nil }
        return catalog.playableVideoTracks.first(where: { $0.name == selectedVideoTrackName })
    }

    var selectedAudioTrack: AudioTrackInfo? {
        guard let selectedAudioTrackName else { return nil }
        return catalog.playableAudioTracks.first(where: { $0.name == selectedAudioTrackName })
    }

    var canStartAudioAnalysis: Bool {
        selectedAudioTrack != nil && !offline
    }

    private let playerEventMonitor: PlayerEventMonitor
    private let dvrPlaybackController: DVRPlaybackController
    private var childObservationCancellables: Set<AnyCancellable> = []
    private var pendingVideoTrackName: String?
    private var lastNonZeroVolume: Double = 1.0

    init(
        catalog: Catalog,
        initialVideoTrackName: String?,
        initialAudioTrackName: String?,
        initialLatencyMs: UInt64
    ) {
        id = catalog.path
        broadcastPath = catalog.path
        selectedVideoTrackName = initialVideoTrackName
        selectedAudioTrackName = initialAudioTrackName
        self.catalog = catalog
        targetLatencyMs = Double(initialLatencyMs)
        playerEventMonitor = PlayerEventMonitor(broadcastPath: catalog.path)
        dvrPlaybackController = DVRPlaybackController(broadcastPath: catalog.path)

        forwardChildChanges()
    }

    func attach(player: Player) {
        broadcastEntryLogger.debug(
            "Attaching player path=\(self.broadcastPath), video=\(self.selectedVideoTrackName ?? "none"), audio=\(self.selectedAudioTrackName ?? "none")"
        )
        self.player = player
        playerEventMonitor.attach(
            to: player,
            activeTrackNames: { [weak self] in
                guard let self else { return (video: nil, audio: nil) }
                return (
                    video: self.selectedVideoTrackName,
                    audio: self.selectedAudioTrackName
                )
            },
            onEvent: { [weak self] event in
                self?.handleEvent(event)
            }
        )
    }

    func switchVideoTrack(to trackName: String) {
        guard catalog.playableVideoTracks.contains(where: { $0.name == trackName }) else { return }
        pendingVideoTrackName = trackName
        Task { try? await player?.switchTrack(to: trackName) }
    }

    // TODO: expose audio-track switching parity with switchVideoTrack - wire through
    // `player?.switchAudioTrack(to:)` and update `selectedAudioTrackName` from
    // `track.select` / `track.switch`. The field is currently set once in `init`.

    func updateTargetLatency(ms: UInt64) {
        targetLatencyMs = Double(ms)
        player?.updateTargetLatency(.milliseconds(Int64(min(ms, UInt64(Int64.max)))))
    }

    func updateVolume(_ newVolume: Double) {
        let clampedVolume = min(max(newVolume, 0), 1)
        volume = clampedVolume
        if clampedVolume > 0 {
            lastNonZeroVolume = clampedVolume
        }
        applySelectedVolume()
    }

    func toggleMute() {
        if volume > 0 {
            updateVolume(0)
        } else {
            updateVolume(lastNonZeroVolume)
        }
    }

    func startDVRIndexing() async {
        await dvrPlaybackController.startIndexing(
            catalog: catalog,
            videoTrackName: selectedVideoTrackName,
            audioTrackName: selectedAudioTrackName
        )
    }

    func rewindLast15Seconds() async {
        await dvrPlaybackController.rewindLast15Seconds(
            catalog: catalog,
            videoTrackName: selectedVideoTrackName,
            audioTrackName: selectedAudioTrackName,
            volume: Float(volume)
        )
        applySelectedVolume()
    }

    func dismissDVR() {
        dvrPlaybackController.dismiss()
        applySelectedVolume()
    }

    func stop(reason: String = "entry stop requested") async {
        broadcastEntryLogger.debug(
            "Stopping broadcast entry path=\(self.broadcastPath), reason=\(reason), hasPlayer=\(self.player != nil), isPlaying=\(self.isPlaying), isPaused=\(self.isPaused), offline=\(self.offline)"
        )
        audioAnalysis.stop(reset: true)
        playerEventMonitor.detach()

        let player = player
        self.player = nil
        isPlaying = false
        isPaused = false

        await dvrPlaybackController.stop()
        await player?.stopAll(reason: reason)
    }

    private func forwardChildChanges() {
        Publishers.Merge(
            playerEventMonitor.objectWillChange,
            dvrPlaybackController.objectWillChange
        )
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservationCancellables)
    }

    private func applySelectedVolume() {
        let selectedVolume = Float(volume)
        dvrPlaybackController.player?.player.volume = selectedVolume
        player?.setVolume(dvrPlaybackController.isPresented ? 0 : selectedVolume)
    }

    private func handleEvent(_ event: PlayerEvent) {
        switch event.type {
        case .playbackStart:
            isPlaying = true
            isPaused = false
        case .playbackPause:
            isPaused = true
        case .playbackResume:
            isPaused = false
        case .trackSwitch(let track):
            guard track.kind == .video else { return }

            let previousTrackName = selectedVideoTrackName
            if let trackName = track.trackName {
                selectedVideoTrackName = trackName
                pendingVideoTrackName = nil
            } else if let pendingVideoTrackName {
                selectedVideoTrackName = pendingVideoTrackName
                self.pendingVideoTrackName = nil
            }
            if selectedVideoTrackName != previousTrackName {
                reindexDVR()
            }
        case .playbackEnd:
            isPlaying = false
            isPaused = false
            offline = true
            audioAnalysis.stop()
        default:
            break
        }
    }

    private func reindexDVR() {
        dvrPlaybackController.reindex(
            catalog: catalog,
            videoTrackName: selectedVideoTrackName,
            audioTrackName: selectedAudioTrackName
        )
    }
}
