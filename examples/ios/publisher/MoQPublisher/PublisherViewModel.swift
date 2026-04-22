import AVFoundation
import MoQKit
import SwiftUI
import os

@MainActor
final class PublisherViewModel: ObservableObject {
    // MARK: - Published State

    @Published var sessionState: SessionState = .idle
    @Published var publisherState: PublisherState = .idle
    @Published var isPreviewRunning = false
    @Published var cameraEnabled = true
    @Published var screenEnabled = false
    @Published var micEnabled = true
    @Published var screenAudioEnabled = false
    @Published var replayKitAppGroupIdentifier = "group.com.swmansion.moqpublisher"
    @Published var replayKitExtensionBundleIdentifier = "com.swmansion.moqpublisher.broadcastupload"
    @Published var replayKitPrepared = false
    @Published var cameraPosition: CameraPosition = .front
    @Published var videoCodec: VideoCodec = .h265
    @Published var videoResolution: VideoResolution = .hd
    @Published var videoFrameRate: VideoFrameRate = .fps30
    @Published var audioCodec: MoQKit.AudioCodec = .opus
    @Published var audioSampleRate: AudioSampleRate = .khz48
    @Published var trackStates: [String: PublishedTrackState] = [:]
    @Published var lastError: String?

    // MARK: - Camera Preview

    private var cameraCapture: CameraCapture?

    var previewSession: AVCaptureSession? {
        cameraCapture?.captureSession
    }

    // MARK: - Capture Sources

    private var camera: CameraCapture?
    private var microphone: MicrophoneCapture?

    // MARK: - Computed Properties

    var canPublish: Bool {
        switch sessionState {
        case .idle, .error, .closed:
            break
        default:
            return false
        }
        if case .publishing = publisherState { return false }
        return cameraEnabled || screenEnabled || micEnabled || screenAudioEnabled
    }

    var hasReplayKitTracks: Bool {
        screenEnabled || screenAudioEnabled
    }

    var hasLocalTracks: Bool {
        cameraEnabled || micEnabled
    }

    var canStop: Bool {
        if case .publishing = publisherState { return true }
        if sessionState == .connecting || sessionState == .connected { return true }
        if replayKitPrepared { return true }
        return false
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

    var publisherStateLabel: String {
        switch publisherState {
        case .idle: return "idle"
        case .publishing: return "publishing"
        case .stopped: return "stopped"
        case .error(let msg): return "error: \(msg)"
        }
    }

    var publisherStateColor: Color {
        switch publisherState {
        case .idle: return .gray
        case .publishing: return .green
        case .stopped: return .orange
        case .error: return .red
        }
    }

    // MARK: - Private State

    private var session: Session?
    private var publisher: Publisher?
    private var stateObserverTask: Task<Void, Never>?
    private var publisherStateTask: Task<Void, Never>?
    private var publisherEventsTask: Task<Void, Never>?
    @Published var publishedTracks: [PublishedTrack] = []

    // MARK: - Camera Preview Lifecycle

    func startPreview() {
        guard cameraCapture == nil, cameraEnabled else { return }

        let cam = CameraCapture(camera: Camera(position: cameraPosition))
        cameraCapture = cam
        isPreviewRunning = true

        Task {
            do {
                try await cam.start()
            } catch {
                lastError = "Camera preview failed: \(error.localizedDescription)"
                cameraCapture = nil
                isPreviewRunning = false
            }
        }
    }

    func stopPreview() {
        cameraCapture?.stop()
        cameraCapture = nil
        isPreviewRunning = false
    }

    func flipCamera() {
        let newPosition: CameraPosition = cameraPosition == .front ? .back : .front
        cameraPosition = newPosition

        if let cameraCapture {
            do {
                try cameraCapture.switch(to: Camera(position: newPosition))
            } catch {
                lastError = "Camera switch failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Publish Lifecycle

    func prepareReplayKitDescriptor(url: String, path: String) {
        do {
            guard !replayKitAppGroupIdentifier.isEmpty else {
                throw ReplayKitBroadcastError.invalidAppGroup("App Group is empty")
            }
            let descriptor = ReplayKitBroadcastDescriptor(
                relayURL: url,
                broadcastPath: path + "/screenshare"
            )
            let store = ReplayKitBroadcastDescriptorStore(
                appGroupIdentifier: replayKitAppGroupIdentifier
            )
            try store.save(descriptor)
            lastError = nil
            replayKitPrepared = true
        } catch {
            print(error)
            lastError = "ReplayKit config failed: \(error.localizedDescription)"
            replayKitPrepared = false
        }
    }

    func publish(url: String, path: String) {
        lastError = nil
        publishedTracks = []
        trackStates = [:]

        if hasReplayKitTracks {
            prepareReplayKitDescriptor(url: url, path: path)
            if lastError != nil { return }
        }

        guard hasLocalTracks else {
            publisherState = .publishing
            return
        }

        let s = Session(url: url)
        session = s

        stateObserverTask = Task {
            for await state in s.state {
                self.sessionState = state
            }
        }

        Task {
            do {
                try await s.connect()

                let pub = try Publisher()
                self.publisher = pub

                // Create and start capture sources, then add tracks
                let videoEncoderConfig = VideoEncoderConfig(
                    codec: self.videoCodec,
                    width: self.videoResolution.width,
                    height: self.videoResolution.height,
                    maxFrameRate: self.videoFrameRate.value
                )
                let audioEncoderConfig = AudioEncoderConfig(
                    codec: self.audioCodec,
                    sampleRate: self.audioSampleRate.value
                )

                if self.cameraEnabled {
                    // Reuse the preview CameraCapture, or create one if preview wasn't started
                    let cam: CameraCapture
                    if let existing = self.cameraCapture {
                        cam = existing
                    } else {
                        cam = CameraCapture(camera: Camera(position: self.cameraPosition))
                        self.cameraCapture = cam
                        try await cam.start()
                    }
                    self.camera = cam

                    let track = pub.addVideoTrack(name: "camera", source: cam, config: videoEncoderConfig)
                    self.publishedTracks.append(track)
                    self.trackStates["camera"] = .idle
                }

                if self.micEnabled {
                    let mic = MicrophoneCapture()
                    self.microphone = mic
                    try await mic.start()

                    let track = pub.addAudioTrack(name: "mic", source: mic, config: audioEncoderConfig)
                    self.publishedTracks.append(track)
                    self.trackStates["mic"] = .idle
                }

                try await s.publish(path: path, publisher: pub)
                try await pub.start()

                self.observePublisher(pub)
            } catch {
                self.lastError = error.localizedDescription
                self.publisherState = .error(error.localizedDescription)
                self.cleanupCaptureSources()
            }
        }
    }

    func stop() {
        let logger = Logger(subsystem: "viewing", category: "PublisherModel")

        logger.info("cancelling tasks")
        publisherStateTask?.cancel()
        publisherStateTask = nil
        publisherEventsTask?.cancel()
        publisherEventsTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        logger.info("tasks cancelled")

        // Capture references before clearing — the detached task needs them.
        let pub = publisher
        publisher = nil
        session = nil
        publishedTracks = []
        trackStates = [:]
        publisherState = .idle
        sessionState = .idle

        // Stop publisher and close session off the main thread.
        // publisher.stop() flushes encoders synchronously — with @MainActor
        // removed from Publisher, this now actually runs off-main.
        Task.detached {
            logger.info("stopping publisher")
            pub?.stop()
            logger.info("publisher stopped")
            logger.info("closing session")
            // await sess?.close()
            logger.info("session closed")
        }

        logger.info("cleaning up capture sources")
        cleanupCaptureSources()
        logger.info("capture sources cleaned up")

        do {
            let store = ReplayKitBroadcastDescriptorStore(
                appGroupIdentifier: replayKitAppGroupIdentifier
            )
            try store.clear()
            replayKitPrepared = false
        } catch {
            lastError = "ReplayKit cleanup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func cleanupCaptureSources() {
        // Don't stop the camera — it's shared with preview via cameraCapture
        camera = nil
        microphone?.stop()
        microphone = nil
    }

    private func observePublisher(_ pub: Publisher) {
        publisherStateTask = Task {
            for await state in pub.state {
                self.publisherState = state
            }
        }

        publisherEventsTask = Task {
            for await event in pub.events {
                switch event {
                case .trackStarted(let name):
                    self.trackStates[name] = .active
                case .trackStopped(let name):
                    self.trackStates[name] = .stopped
                case .error(let name, let msg):
                    self.trackStates[name] = .stopped
                    self.lastError = "\(name): \(msg)"
                }
            }
        }

        // Observe individual track states
        for track in publishedTracks {
            let name = track.name
            Task {
                for await state in track.state {
                    self.trackStates[name] = state
                }
            }
        }
    }

}
