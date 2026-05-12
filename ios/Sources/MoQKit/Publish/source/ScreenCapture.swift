import CoreMedia
import ReplayKit

/// Lightweight frame source for manually forwarding sample buffers into a publisher track.
///
/// MoQKit uses `FrameRelay` internally for ReplayKit and screen-capture helpers. You can
/// also use it when your app already receives `CMSampleBuffer` values from another source
/// and only needs a simple bridge into ``Publisher``.
public final class FrameRelay: FrameSource, @unchecked Sendable {
    /// Advanced frame callback used by ``Publisher``.
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    /// Creates an empty relay with no consumer attached yet.
    public init() {}

    /// Forwards one sample buffer to the attached consumer.
    ///
    /// Returns `false` when the consumer asked the source to stop, or `true` when the
    /// frame was accepted or no consumer is attached yet.
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
    /// Video frames produced by screen capture.
    public let videoSource = FrameRelay()
    /// App-audio frames produced by screen capture.
    ///
    /// Microphone audio is not published here; use ``MicrophoneCapture`` for that.
    public let audioSource = FrameRelay()

    private var isRunning = false

    /// Creates an in-app screen capture source.
    public init() {}

    /// Starts in-app screen capture.
    ///
    /// This captures screen video plus app audio from `RPScreenRecorder`. It is best for
    /// “share this app” style flows. Use ReplayKit Broadcast Upload for full-device capture.
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

    /// Stops screen capture and detaches the video and audio relays.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        RPScreenRecorder.shared().stopCapture()
        videoSource.onFrame = nil
        audioSource.onFrame = nil
    }
}
