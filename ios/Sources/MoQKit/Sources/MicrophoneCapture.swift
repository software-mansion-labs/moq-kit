import AVFoundation

/// Wraps `AVCaptureSession` to capture raw PCM audio from the microphone.
public final class MicrophoneCapture: NSObject, MoQFrameSource, @unchecked Sendable {
    private let session = AVCaptureSession()
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
                    session.beginConfiguration()

                    guard let device = AVCaptureDevice.default(for: .audio) else {
                        throw MoQSessionError.invalidConfiguration("No microphone available")
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add microphone input")
                    }
                    session.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add audio output")
                    }
                    session.addOutput(output)

                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            self.session.stopRunning()
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
