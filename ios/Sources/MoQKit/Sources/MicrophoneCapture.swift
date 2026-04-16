import AVFoundation

/// Wraps `AVCaptureSession` to capture raw PCM audio from the microphone.
final class MicrophoneCapture: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.MicrophoneCapture")
    private var handler: ((CMSampleBuffer) -> Void)?

    func start(handler: @escaping (CMSampleBuffer) -> Void) async throws {
        self.handler = handler

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

    func stop() {
        session.stopRunning()
        handler = nil
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handler?(sampleBuffer)
    }
}
