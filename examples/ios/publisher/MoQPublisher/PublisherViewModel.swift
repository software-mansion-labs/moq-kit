import AVFoundation
import MoQKit
import SwiftUI

@MainActor
final class PublisherViewModel: ObservableObject {
    // MARK: - Published State

    @Published var sessionState: MoQSessionState = .idle
    @Published var publisherState: MoQPublisherState = .idle
    @Published var isPreviewRunning = false
    @Published var cameraEnabled = true
    @Published var screenEnabled = false
    @Published var micEnabled = true
    @Published var screenAudioEnabled = false
    @Published var cameraPosition: MoQCameraPosition = .front
    @Published var trackStates: [String: MoQPublishedTrackState] = [:]
    @Published var lastError: String?

    // MARK: - Camera Preview

    private(set) var captureSession: AVCaptureSession?

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

    var canStop: Bool {
        if case .publishing = publisherState { return true }
        if sessionState == .connecting || sessionState == .connected { return true }
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

    private var session: MoQSession?
    private var publisher: MoQPublisher?
    private var stateObserverTask: Task<Void, Never>?
    private var publisherStateTask: Task<Void, Never>?
    private var publisherEventsTask: Task<Void, Never>?
    private var publishedTracks: [MoQPublishedTrack] = []

    // MARK: - Camera Preview Lifecycle

    func startPreview() {
        guard captureSession == nil, cameraEnabled else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = cameraDevice(for: cameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }

        session.addInput(input)

        captureSession = session
        isPreviewRunning = true
        Task.detached { session.startRunning() }
    }

    func stopPreview() {
        guard let session = captureSession else { return }
        let s = session
        captureSession = nil
        isPreviewRunning = false
        Task.detached { s.stopRunning() }
    }

    func flipCamera() {
        cameraPosition = cameraPosition == .front ? .back : .front
        if isPreviewRunning {
            stopPreview()
            startPreview()
        }
    }

    // MARK: - Publish Lifecycle

    func publish(url: String, path: String) {
        lastError = nil
        trackStates = [:]

        // Stop camera preview to release the camera for MoQPublisher
        stopPreview()

        let s = MoQSession(url: url)
        session = s

        stateObserverTask = Task {
            for await state in s.state {
                self.sessionState = state
            }
        }

        Task {
            do {
                try await s.connect()

                let pub = try MoQPublisher()
                self.publisher = pub

                if self.cameraEnabled {
                    let track = pub.addVideoTrack(
                        name: "camera",
                        input: .camera(position: self.cameraPosition))
                    self.publishedTracks.append(track)
                    self.trackStates["camera"] = .idle
                }
                if self.screenEnabled {
                    let track = pub.addVideoTrack(name: "screen", input: .screen)
                    self.publishedTracks.append(track)
                    self.trackStates["screen"] = .idle
                }
                if self.micEnabled {
                    let track = pub.addAudioTrack(name: "mic", input: .microphone)
                    self.publishedTracks.append(track)
                    self.trackStates["mic"] = .idle
                }
                if self.screenAudioEnabled {
                    let track = pub.addAudioTrack(name: "screen-audio", input: .screenAudio)
                    self.publishedTracks.append(track)
                    self.trackStates["screen-audio"] = .idle
                }

                try s.publish(path: path, publisher: pub)
                try await pub.start()

                self.observePublisher(pub)
            } catch {
                self.lastError = error.localizedDescription
                self.publisherState = .error(error.localizedDescription)
                if self.cameraEnabled { self.startPreview() }
            }
        }
    }

    func stop() {
        publisherStateTask?.cancel()
        publisherStateTask = nil
        publisherEventsTask?.cancel()
        publisherEventsTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil

        let pub = publisher
        let s = session

        publisher = nil
        session = nil
        publishedTracks = []
        trackStates = [:]
        publisherState = .idle
        sessionState = .idle

        Task {
            if let pub {
                pub.stop()
            }
            await s?.close()
        }

        if cameraEnabled {
            startPreview()
        }
    }

    // MARK: - Private

    private func observePublisher(_ pub: MoQPublisher) {
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

    private func cameraDevice(for position: MoQCameraPosition) -> AVCaptureDevice? {
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition)
    }
}
