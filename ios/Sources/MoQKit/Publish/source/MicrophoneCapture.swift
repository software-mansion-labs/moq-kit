import AVFoundation

/// Built-in microphone capture source for publishing raw PCM audio.
///
/// Your app must include `NSMicrophoneUsageDescription` and configure `AVAudioSession`
/// before starting microphone capture. MoQKit uses the app's audio session as-is.
public final class MicrophoneCapture: NSObject, FrameSource, @unchecked Sendable {
    /// The underlying capture session for advanced configuration if needed.
    public let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.MicrophoneCapture")
    /// Advanced frame callback used by ``Publisher``.
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureAudioDataOutput?
    private var isConfigured = false
    private var isRunning = false

    /// Creates a microphone capture source for the current system input route.
    public override init() {
        super.init()
    }

    /// Starts microphone capture.
    ///
    /// The source captures raw PCM audio and begins forwarding frames once a publisher
    /// track attaches an ``FrameSource/onFrame`` callback.
    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !isConfigured {
                        try configureSession()
                    }

                    if !isRunning {
                        captureSession.startRunning()
                        isRunning = true
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops microphone capture and detaches any active frame consumer.
    public func stop() {
        onFrame = nil
        queue.async { [self] in
            if isRunning {
                captureSession.stopRunning()
                isRunning = false
            }
        }
    }

    private func configureSession() throws {
        captureSession.usesApplicationAudioSession = true
        captureSession.automaticallyConfiguresApplicationAudioSession = false

        captureSession.beginConfiguration()
        do {
            // Checking for empty uniqueID ensures that we didn't receive a mock device, i.e. the one created by iOS Simulator.
            // Otherwise AVCaptureDeviceInput will crash the app.
            guard let device = AVCaptureDevice.default(for: .audio), !device.uniqueID.isEmpty else {
                throw SessionError.invalidConfiguration("No microphone available")
            }

            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw SessionError.invalidConfiguration("Cannot add microphone input")
            }
            captureSession.addInput(input)
            currentInput = input

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard captureSession.canAddOutput(output) else {
                throw SessionError.invalidConfiguration("Cannot add audio output")
            }
            captureSession.addOutput(output)
            currentOutput = output

            captureSession.commitConfiguration()
            isConfigured = true
        } catch {
            captureSession.commitConfiguration()
            resetSession()
            throw error
        }
    }

    private func resetSession() {
        guard currentInput != nil || currentOutput != nil else { return }

        if isRunning {
            captureSession.stopRunning()
            isRunning = false
        }

        captureSession.beginConfiguration()
        if let output = currentOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
            captureSession.removeOutput(output)
        }
        if let input = currentInput {
            captureSession.removeInput(input)
        }
        captureSession.commitConfiguration()
        currentInput = nil
        currentOutput = nil
        isConfigured = false
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    /// AVFoundation delegate callback used internally to forward captured audio frames.
    ///
    /// Apps normally do not call this directly.
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
