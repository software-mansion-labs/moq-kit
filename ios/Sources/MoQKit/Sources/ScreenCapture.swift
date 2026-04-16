import ReplayKit
import CoreMedia

/// Wraps `RPScreenRecorder` to capture the device screen and optionally app audio.
final class ScreenCapture: @unchecked Sendable {
    private var videoHandler: ((CMSampleBuffer) -> Void)?
    private var audioHandler: ((CMSampleBuffer) -> Void)?
    private var isRunning = false

    func start(
        videoHandler: @escaping (CMSampleBuffer) -> Void,
        audioHandler: ((CMSampleBuffer) -> Void)? = nil
    ) async throws {
        self.videoHandler = videoHandler
        self.audioHandler = audioHandler

        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw MoQSessionError.invalidConfiguration("Screen recording is not available")
        }

        try await recorder.startCapture { [weak self] sampleBuffer, sampleType, error in
            guard error == nil, let self else { return }
            switch sampleType {
            case .video:
                self.videoHandler?(sampleBuffer)
            case .audioApp:
                self.audioHandler?(sampleBuffer)
            case .audioMic:
                // Mic audio from screen capture is not used; use MicrophoneCapture instead
                break
            @unknown default:
                break
            }
        }
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        try? await RPScreenRecorder.shared().stopCapture()
        videoHandler = nil
        audioHandler = nil
    }
}
