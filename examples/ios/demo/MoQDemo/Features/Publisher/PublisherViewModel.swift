import AVFoundation
import MoQKit
import SwiftUI
import os

private let publisherDemoLogger = Logger(
    subsystem: "com.swmansion.MoQDemo",
    category: "publisher-demo"
)

@MainActor
final class PublisherViewModel: ObservableObject {
    // MARK: - Published State

    @Published var sessionState: SessionState = .idle
    @Published var publisherState: PublisherState = .idle
    @Published var isPreviewRunning = false
    @Published var cameraEnabled = true
    @Published var screenEnabled = false
    @Published var micEnabled = true
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isChangingMedia = false
    @Published private(set) var isCameraCapturing = false
    @Published private(set) var isMicrophoneCapturing = false
    @Published private(set) var publicationEnabled: [String: Bool] = [:]
    private var operationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
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
    @Published var lastError: String? {
        didSet {
            if let lastError {
                publisherDemoLogger.error("\(lastError)")
            }
        }
    }

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
        return !isChangingMedia && publishUnsupportedReason(videoConfig: currentVideoConfig(), audioConfig: currentAudioConfig()) == nil
    }

    var hasReplayKitTracks: Bool {
        screenEnabled || screenAudioEnabled
    }

    var hasLocalTracks: Bool {
        cameraSourceMode == .singleCamera || cameraEnabled || micEnabled
    }

    var canMuteMicrophone: Bool {
        publisherState == .publishing && microphone != nil && !isChangingMedia
    }

    func toggleMicrophoneMute() {
        guard canMuteMicrophone, let microphone else { return }
        microphone.isMuted.toggle()
        isMicrophoneMuted = microphone.isMuted
    }

    func toggleCameraCapture() {
        guard let camera = cameraCapture else { return }
        changeMedia {
            if camera.isCapturing { await camera.stop() }
            else { try await camera.start() }
            self.isCameraCapturing = camera.isCapturing
            self.isPreviewRunning = camera.isCapturing
        }
    }

    func toggleMicrophoneCapture() {
        guard let microphone else { return }
        changeMedia {
            if microphone.isCapturing { await microphone.stop() }
            else { try await microphone.start() }
            self.isMicrophoneCapturing = microphone.isCapturing
        }
    }

    func togglePublication(_ track: PublishedMediaTrack) {
        changeMedia {
            try await track.setEnabled(!track.isEnabled)
            self.publicationEnabled[track.name] = track.isEnabled
        }
    }

    private func changeMedia(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isChangingMedia else { return }
        isChangingMedia = true
        operationTask = Task {
            defer { isChangingMedia = false }
            do { try await action() }
            catch { lastError = error.localizedDescription }
        }
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
        let cam = cameraCapture ?? CameraCapture(camera: Camera(position: cameraPosition))
        cameraCapture = cam
        isPreviewRunning = true

        previewTask?.cancel()
        previewTask = Task {
            do {
                try await cam.start()
                isCameraCapturing = cam.isCapturing
            } catch {
                lastError = "Camera preview failed: \(error.localizedDescription)"
                if cameraCapture === cam { isPreviewRunning = false }
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
        let cam = cameraCapture
        cameraCapture = nil
        let pending = previewTask
        pending?.cancel()
        previewTask = Task {
            await pending?.value
            await cam?.close()
            isCameraCapturing = false
        }
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

        isChangingMedia = true
        operationTask = Task {
            defer { isChangingMedia = false }
            do {
                try await s.connect()
                try Task.checkCancellation()

                let pub = try Publisher()
                self.publisher = pub

                if self.cameraEnabled || self.cameraSourceMode == .singleCamera {
                    switch self.cameraSourceMode {
                    case .singleCamera:
                        // Reuse the preview CameraCapture, or create one if preview wasn't started
                        let cam: CameraCapture
                        if let existing = self.cameraCapture {
                            cam = existing
                        } else {
                            cam = CameraCapture(camera: Camera(position: self.cameraPosition))
                            self.cameraCapture = cam
                        }
                        self.camera = cam

                        let track = try pub.addVideoTrack(name: "camera", source: cam, config: videoEncoderConfig)
                        self.publishedTracks.append(track)
                        self.trackStates["camera"] = .idle

                    case .multiCamera:
                        let multi = try await self.runningMultiCameraCapture(
                            videoConfig: videoEncoderConfig
                        )

                        let frontTrack = try pub.addVideoTrack(
                            name: "front-camera",
                            source: multi.frontSource,
                            config: videoEncoderConfig
                        )
                        self.publishedTracks.append(frontTrack)
                        self.trackStates["front-camera"] = .idle

                        let backTrack = try pub.addVideoTrack(
                            name: "back-camera",
                            source: multi.backSource,
                            config: videoEncoderConfig
                        )
                        self.publishedTracks.append(backTrack)
                        self.trackStates["back-camera"] = .idle
                    }
                }

                do {
                    let mic = MicrophoneCapture()
                    self.microphone = mic

                    let track = try pub.addAudioTrack(name: "mic", source: mic, config: audioEncoderConfig)
                    self.publishedTracks.append(track)
                    self.trackStates["mic"] = .idle
                }

                try await s.publish(path: path, publisher: pub)
                try await pub.start()

                self.observePublisher(pub)
                for track in self.publishedTracks {
                    if let media = track as? PublishedMediaTrack {
                        self.publicationEnabled[track.name] = media.isEnabled
                    }
                }
                if self.cameraEnabled { try await self.cameraCapture?.start() }
                if self.micEnabled { try await self.microphone?.start() }
                self.isCameraCapturing = self.cameraCapture?.isCapturing ?? false
                self.isPreviewRunning = self.isCameraCapturing || self.multiCamera != nil
                self.isMicrophoneCapturing = self.microphone?.isCapturing ?? false
            } catch {
                self.lastError = error.localizedDescription
                self.publisherState = .error(error.localizedDescription)
                await self.publisher?.stop()
                await s.close()
                await self.cleanupCaptureSources()
            }
        }
    }

    func stop() {
        let pending = operationTask
        pending?.cancel()
        isChangingMedia = true
        operationTask = Task {
            await pending?.value
            publisherStateTask?.cancel()
            publisherEventsTask?.cancel()
            stateObserverTask?.cancel()
            await publisher?.stop()
            await session?.close()
            await cleanupCaptureSources()
            publisher = nil
            session = nil
            publishedTracks = []
            trackStates = [:]
            publicationEnabled = [:]
            publisherState = .idle
            sessionState = .idle
            isChangingMedia = false
            Self.configurePlaybackAudioSession()
            do {
                try ReplayKitBroadcastDescriptorStore(
                    appGroupIdentifier: replayKitAppGroupIdentifier
                ).clear()
                replayKitPrepared = false
            } catch { lastError = error.localizedDescription }
        }
    }

    // MARK: - Private

    private func cleanupCaptureSources() async {
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
        await microphone?.close()
        microphone = nil
        isMicrophoneMuted = false
        isMicrophoneCapturing = false
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
                case .trackStarted, .trackStopped:
                    break
                case .error(let name, let msg):
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
