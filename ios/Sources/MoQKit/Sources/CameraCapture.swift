import AVFoundation

/// Wraps `AVCaptureSession` to capture video frames from a camera device.
final class CameraCapture: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.CameraCapture")
    private var handler: ((CMSampleBuffer) -> Void)?

    private let position: AVCaptureDevice.Position
    private let width: Int32
    private let height: Int32

    init(position: AVCaptureDevice.Position, width: Int32, height: Int32) {
        self.position = position
        self.width = width
        self.height = height
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

                    // Video output
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)

                    if let connection = output.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .landscapeRight
                        }
                    }

                    guard session.canAddOutput(output) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add video output")
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
