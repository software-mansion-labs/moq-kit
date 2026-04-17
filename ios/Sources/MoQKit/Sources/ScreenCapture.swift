import ReplayKit
import CoreMedia

/// Wraps `RPScreenRecorder` to capture the device screen and optionally app audio.
public final class ScreenCapture: @unchecked Sendable {
    /// Frame source for captured video frames.
    public let videoSource = MoQFrameRelay()
    /// Frame source for captured app audio frames.
    public let audioSource = MoQFrameRelay()

    private var isRunning = false

    public init() {}

    public func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw MoQSessionError.invalidConfiguration("Screen recording is not available")
        }

        try await recorder.startCapture { [weak self] sampleBuffer, sampleType, error in
            guard error == nil, let self else { return }
            switch sampleType {
            case .video:
                if !self.videoSource.send(sampleBuffer) {
                    Task { await self.stop() }
                }
            case .audioApp:
                if !self.audioSource.send(sampleBuffer) {
                    Task { await self.stop() }
                }
            case .audioMic:
                // Mic audio from screen capture is not used; use MicrophoneCapture instead
                break
            @unknown default:
                break
            }
        }
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        try? await RPScreenRecorder.shared().stopCapture()
        videoSource.onFrame = nil
        audioSource.onFrame = nil
    }
}
