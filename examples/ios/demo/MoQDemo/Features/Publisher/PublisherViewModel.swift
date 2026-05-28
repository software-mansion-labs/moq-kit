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
    @Published var replayKitAppGroupIdentifier = "group.com.swmansion.moqdemo"
    @Published var replayKitExtensionBundleIdentifier = "com.swmansion.moqdemo.broadcastupload"
    @Published var replayKitPrepared = false
    @Published var cameraSourceMode: CameraSourceMode = .singleCamera
    @Published var cameraPosition: CameraPosition = .front
    @Published var multiCameraMainPreviewPosition: CameraPosition = .back
    @Published var videoCodec: VideoCodec = PublisherViewModel.defaultVideoCodec()
    @Published var videoResolution: VideoResolution = .hd
    @Published var videoFrameRate: VideoFrameRate = .fps30
    @Published var audioCodec: MoQKit.AudioCodec = PublisherViewModel.defaultAudioCodec()
    @Published var audioSampleRate: AudioSampleRate = .khz48
    @Published var trackStates: [String: PublishedTrackState] = [:]
    @Published var lastError: String?

    // MARK: - Camera Preview

    private var cameraCapture: CameraCapture?

    var previewSession: AVCaptureSession? {
        cameraCapture?.captureSession
    }

    var multiCameraPreviewSession: AVCaptureMultiCamSession? {
        multiCamera?.captureSession
    }

    // MARK: - Capture Sources

    private var camera: CameraCapture?
    private var multiCamera: MultiCameraCapture?
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
        return (cameraEnabled || screenEnabled || micEnabled || screenAudioEnabled)
            && publishUnsupportedReason(videoConfig: currentVideoConfig(), audioConfig: currentAudioConfig()) == nil
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

    var supportedVideoCodecs: [VideoCodec] {
        VideoEncoderConfig.supportedCodecs()
    }

    var supportedAudioCodecs: [MoQKit.AudioCodec] {
        AudioEncoderConfig.supportedCodecs()
    }

    var stateLabel: String {
        switch sessionState {
        case .idle: return "idle"
        case .connecting: return "connecting..."
        case .connected: return "connected"
        case .error(let error): return "error: \(error.localizedDescription)"
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
        guard cameraEnabled else { return }

        switch cameraSourceMode {
        case .singleCamera:
            startSingleCameraPreview()
        case .multiCamera:
            startMultiCameraPreview()
        }
    }

    private func startSingleCameraPreview() {
        stopMultiCameraPreview()
        guard cameraCapture == nil else {
            isPreviewRunning = true
            return
        }

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

    private func startMultiCameraPreview(videoConfig: VideoEncoderConfig? = nil) {
        guard MultiCameraCapture.isSupported else {
            lastError = "Multi-camera capture is not supported on this device"
            cameraSourceMode = .singleCamera
            startSingleCameraPreview()
            return
        }

        stopSingleCameraPreview()

        let videoConfig = videoConfig ?? currentVideoConfig()
        if let existing = multiCamera {
            guard !isMultiCamera(existing, configuredFor: videoConfig) else {
                isPreviewRunning = true
                return
            }
            existing.stop()
            multiCamera = nil
        }

        let multi = makeMultiCameraCapture(videoConfig: videoConfig)
        multiCamera = multi
        isPreviewRunning = false

        Task {
            do {
                try await multi.start()
                if self.multiCamera === multi {
                    self.isPreviewRunning = true
                    self.lastError = nil
                }
            } catch {
                if self.multiCamera === multi {
                    self.lastError = "Multi-camera preview failed: \(error.localizedDescription)"
                    self.multiCamera = nil
                    self.isPreviewRunning = false
                }
            }
        }
    }

    func stopPreview() {
        stopSingleCameraPreview()
        stopMultiCameraPreview()
        isPreviewRunning = false
    }

    private func stopSingleCameraPreview() {
        cameraCapture?.stop()
        cameraCapture = nil
    }

    private func stopMultiCameraPreview() {
        multiCamera?.stop()
        multiCamera = nil
    }

    func flipCamera() {
        guard cameraSourceMode == .singleCamera else { return }
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

    func swapMultiCameraPreview() {
        multiCameraMainPreviewPosition = multiCameraMainPreviewPosition == .front ? .back : .front
    }

    func handleCameraEnabledChanged() {
        if cameraEnabled {
            handleCameraSourceChanged()
        } else {
            stopPreview()
        }
    }

    func handleCameraSourceChanged() {
        guard cameraEnabled else { return }

        switch cameraSourceMode {
        case .singleCamera:
            startSingleCameraPreview()
        case .multiCamera:
            if !MultiCameraCapture.isSupported {
                cameraSourceMode = .singleCamera
                lastError = "Multi-camera capture is not supported on this device"
                startSingleCameraPreview()
                return
            }
            startMultiCameraPreview()
        }
    }

    // MARK: - Publish Lifecycle

    static func configurePlaybackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
        try? audioSession.setActive(true)
    }

    private func configurePublishingAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try? audioSession.setActive(true)
    }

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
        configurePublishingAudioSession()

        lastError = nil
        publishedTracks = []
        trackStates = [:]

        let videoEncoderConfig = currentVideoConfig()
        let audioEncoderConfig = currentAudioConfig()
        if let unsupportedReason = publishUnsupportedReason(
            videoConfig: videoEncoderConfig,
            audioConfig: audioEncoderConfig
        ) {
            lastError = unsupportedReason
            publisherState = .error(unsupportedReason)
            return
        }

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

                if self.cameraEnabled {
                    switch self.cameraSourceMode {
                    case .singleCamera:
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

                    case .multiCamera:
                        let multi = try await self.runningMultiCameraCapture(
                            videoConfig: videoEncoderConfig
                        )

                        let frontTrack = pub.addVideoTrack(
                            name: "front-camera",
                            source: multi.frontSource,
                            config: videoEncoderConfig
                        )
                        self.publishedTracks.append(frontTrack)
                        self.trackStates["front-camera"] = .idle

                        let backTrack = pub.addVideoTrack(
                            name: "back-camera",
                            source: multi.backSource,
                            config: videoEncoderConfig
                        )
                        self.publishedTracks.append(backTrack)
                        self.trackStates["back-camera"] = .idle
                    }
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
        Self.configurePlaybackAudioSession()

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
        if cameraEnabled && cameraSourceMode == .multiCamera && multiCamera != nil {
            isPreviewRunning = true
        } else {
            multiCamera?.stop()
            multiCamera = nil
            if cameraSourceMode == .multiCamera {
                isPreviewRunning = false
            }
        }
        microphone?.stop()
        microphone = nil
    }

    private func runningMultiCameraCapture(
        videoConfig: VideoEncoderConfig
    ) async throws -> MultiCameraCapture {
        if let existing = multiCamera {
            if isMultiCamera(existing, configuredFor: videoConfig) {
                try await existing.start()
                isPreviewRunning = true
                return existing
            }

            existing.stop()
            multiCamera = nil
            isPreviewRunning = false
        }

        let multi = makeMultiCameraCapture(videoConfig: videoConfig)
        multiCamera = multi

        do {
            try await multi.start()
            isPreviewRunning = true
            return multi
        } catch {
            if multiCamera === multi {
                multiCamera = nil
                isPreviewRunning = false
            }
            throw error
        }
    }

    private func makeMultiCameraCapture(videoConfig: VideoEncoderConfig) -> MultiCameraCapture {
        MultiCameraCapture(
            front: Camera(
                position: .front,
                width: videoConfig.width,
                height: videoConfig.height
            ),
            back: Camera(
                position: .back,
                width: videoConfig.width,
                height: videoConfig.height
            ),
            maxFrameRate: videoConfig.maxFrameRate
        )
    }

    private func isMultiCamera(
        _ multi: MultiCameraCapture,
        configuredFor videoConfig: VideoEncoderConfig
    ) -> Bool {
        multi.front.width == videoConfig.width
            && multi.front.height == videoConfig.height
            && multi.back.width == videoConfig.width
            && multi.back.height == videoConfig.height
            && multi.maxFrameRate == videoConfig.maxFrameRate
    }

    private func currentVideoConfig() -> VideoEncoderConfig {
        VideoEncoderConfig(
            codec: videoCodec,
            width: videoResolution.width,
            height: videoResolution.height,
            maxFrameRate: videoFrameRate.value
        )
    }

    private func currentAudioConfig() -> AudioEncoderConfig {
        AudioEncoderConfig(
            codec: audioCodec,
            sampleRate: audioSampleRate.value
        )
    }

    private func publishUnsupportedReason(
        videoConfig: VideoEncoderConfig,
        audioConfig: AudioEncoderConfig
    ) -> String? {
        if cameraEnabled && cameraSourceMode == .multiCamera && !MultiCameraCapture.isSupported {
            return "Multi-camera capture is not supported on this device"
        }
        if (cameraEnabled || screenEnabled), let reason = videoConfig.unsupportedReason {
            return reason
        }
        if (micEnabled || screenAudioEnabled), let reason = audioConfig.unsupportedReason {
            return reason
        }
        return nil
    }

    private static func defaultVideoCodec() -> VideoCodec {
        let supported = VideoEncoderConfig.supportedCodecs()
        if supported.contains(.h265) { return .h265 }
        return supported.first ?? .h264
    }

    private static func defaultAudioCodec() -> MoQKit.AudioCodec {
        let supported = AudioEncoderConfig.supportedCodecs()
        if supported.contains(.opus) { return .opus }
        return supported.first ?? .aac
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
