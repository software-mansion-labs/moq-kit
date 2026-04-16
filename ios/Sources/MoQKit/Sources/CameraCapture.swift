import AVFoundation

/// Wraps `AVCaptureSession` to capture video frames from a camera device.
final class CameraCapture: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.CameraCapture")
    private var handler: ((CMSampleBuffer) -> Void)?

    private(set) var position: AVCaptureDevice.Position
    private let width: Int32
    private let height: Int32
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureVideoDataOutput?
    private(set) var currentOrientation: AVCaptureVideoOrientation

    init(
        position: AVCaptureDevice.Position,
        width: Int32,
        height: Int32,
        orientation: AVCaptureVideoOrientation = .portrait
    ) {
        self.position = position
        self.width = width
        self.height = height
        self.currentOrientation = orientation
        super.init()
    }

    func start(handler: @escaping (CMSampleBuffer) -> Void) async throws {
        self.handler = handler

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.beginConfiguration()

                    // Pick a session preset based on requested dimensions
                    let preset = sessionPreset(for: width, height: height)
                    if session.canSetSessionPreset(preset) {
                        session.sessionPreset = preset
                    }

                    // Camera input
                    guard
                        let device = AVCaptureDevice.default(
                            .builtInWideAngleCamera, for: .video, position: position
                        )
                    else {
                        throw MoQSessionError.invalidConfiguration(
                            "No camera available for position \(position)")
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add camera input")
                    }
                    session.addInput(input)
                    currentInput = input

                    // Video output
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)

                    guard session.canAddOutput(output) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add video output")
                    }
                    session.addOutput(output)
                    currentOutput = output

                    if let connection = output.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = currentOrientation
                        }
                    }

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
        queue.async { [self] in
            self.session.stopRunning()
        }
        handler = nil
    }

    /// Switch to a different camera while the session is running.
    func switchCamera(to newPosition: AVCaptureDevice.Position) throws {
        try queue.sync {
            guard let oldInput = currentInput else {
                throw MoQSessionError.invalidConfiguration("No current camera input")
            }
            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: newPosition
                )
            else {
                throw MoQSessionError.invalidConfiguration(
                    "No camera available for position \(newPosition)")
            }

            let newInput = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            session.removeInput(oldInput)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentInput = newInput
                position = newPosition
            } else {
                // Rollback
                session.addInput(oldInput)
                session.commitConfiguration()
                throw MoQSessionError.invalidConfiguration("Cannot add new camera input")
            }
            session.commitConfiguration()
        }
    }

    /// Update the capture orientation.
    func setOrientation(_ orientation: AVCaptureVideoOrientation) {
        queue.async { [self] in
            currentOrientation = orientation
            if let connection = currentOutput?.connection(with: .video),
                connection.isVideoOrientationSupported
            {
                connection.videoOrientation = orientation
            }
        }
    }

    private func sessionPreset(for width: Int32, height: Int32) -> AVCaptureSession.Preset {
        let pixels = Int(width) * Int(height)
        if pixels <= 640 * 480 { return .vga640x480 }
        if pixels <= 1280 * 720 { return .hd1280x720 }
        if pixels <= 1920 * 1080 { return .hd1920x1080 }
        return .hd4K3840x2160
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handler?(sampleBuffer)
    }
}
