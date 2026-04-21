import CoreMedia
import ReplayKit

/// A passthrough frame source for wiring non-conforming producers
/// (e.g. ScreenCapture's separate video/audio streams).
public final class FrameRelay: FrameSource, @unchecked Sendable {
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    public init() {}

    /// Feed a frame to the consumer. Returns `false` if the consumer signaled stop,
    /// or `true` if no consumer is attached.
    @discardableResult
    public func send(_ sampleBuffer: CMSampleBuffer) -> Bool {
        onFrame?(sampleBuffer) ?? true
    }
}

/// Wraps `RPScreenRecorder` to capture in-app screen frames and optionally app audio.
///
/// Important: this capture mode runs inside the host app process. When the app is
/// backgrounded (for example after switching to another app), delivery of frames can
/// stop. For full-device capture across app switches, use ReplayKit Broadcast Upload
/// Extension flow with ``ReplayKitBroadcastPipeline``.
public final class ScreenCapture: @unchecked Sendable {
    /// Frame source for captured video frames.
    public let videoSource = FrameRelay()
    /// Frame source for captured app audio frames.
    public let audioSource = FrameRelay()

    private var isRunning = false

    public init() {}

    public func start() async throws {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw SessionError.invalidConfiguration("Screen recording is not available")
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
        RPScreenRecorder.shared().stopCapture()
        videoSource.onFrame = nil
        audioSource.onFrame = nil
    }
}
