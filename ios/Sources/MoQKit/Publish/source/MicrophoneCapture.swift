import AVFoundation

/// Wraps `AVCaptureSession` to capture raw PCM audio from the current system microphone route.
public final class MicrophoneCapture: NSObject, FrameSource, @unchecked Sendable {
    public let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.MicrophoneCapture")
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    public override init() {
        super.init()
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    captureSession.usesApplicationAudioSession = true
                    captureSession.automaticallyConfiguresApplicationAudioSession = false
                    captureSession.beginConfiguration()

                    guard let device = AVCaptureDevice.default(for: .audio) else {
                        throw SessionError.invalidConfiguration("No microphone available")
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard captureSession.canAddInput(input) else {
                        throw SessionError.invalidConfiguration("Cannot add microphone input")
                    }
                    captureSession.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard captureSession.canAddOutput(output) else {
                        throw SessionError.invalidConfiguration("Cannot add audio output")
                    }
                    captureSession.addOutput(output)

                    captureSession.commitConfiguration()
                    captureSession.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            self.captureSession.stopRunning()
        }
        onFrame = nil
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let onFrame, !onFrame(sampleBuffer) {
            stop()
        }
    }
}
