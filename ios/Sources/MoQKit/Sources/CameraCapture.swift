import AVFoundation

/// Camera position for video capture.
public enum MoQCameraPosition: Sendable {
    case front, back

    var position: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

/// Video capture orientation.
public enum MoQVideoOrientation: Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeRight
    case landscapeLeft

    var avOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        }
    }

    var isLandscape: Bool {
        self == .landscapeRight || self == .landscapeLeft
    }
}

/// Wraps `AVCaptureSession` to capture video frames from a camera device.
public final class CameraCapture: NSObject, MoQFrameSource, @unchecked Sendable {
    public let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.CameraCapture")
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    private(set) var position: AVCaptureDevice.Position
    private let width: Int32
    private let height: Int32
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureVideoDataOutput?
    private(set) var currentOrientation: AVCaptureVideoOrientation

    public init(
        position: MoQCameraPosition = .back,
        width: Int32 = 720,
        height: Int32 = 1280,
        orientation: MoQVideoOrientation = .portrait
    ) {
        self.position = position.position
        self.width = width
        self.height = height
        self.currentOrientation = orientation.avOrientation
        super.init()
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    captureSession.beginConfiguration()

                    // Pick a session preset based on requested dimensions
                    let preset = sessionPreset(for: width, height: height)
                    if captureSession.canSetSessionPreset(preset) {
                        captureSession.sessionPreset = preset
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
                    guard captureSession.canAddInput(input) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add camera input")
                    }
                    captureSession.addInput(input)
                    currentInput = input

                    // Video output
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)

                    guard captureSession.canAddOutput(output) else {
                        throw MoQSessionError.invalidConfiguration("Cannot add video output")
                    }
                    captureSession.addOutput(output)
                    currentOutput = output

                    if let connection = output.connection(with: .video) {
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = currentOrientation
                        }
                    }

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

    /// Switch to a different camera while the session is running.
    public func switchCamera(to newPosition: MoQCameraPosition) throws {
        let avPosition = newPosition.position
        try queue.sync {
            guard let oldInput = currentInput else {
                throw MoQSessionError.invalidConfiguration("No current camera input")
            }
            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: avPosition
                )
            else {
                throw MoQSessionError.invalidConfiguration(
                    "No camera available for position \(avPosition)")
            }

            let newInput = try AVCaptureDeviceInput(device: device)

            captureSession.beginConfiguration()
            
            // Pick a session preset based on requested dimensions
            let preset = sessionPreset(for: width, height: height)
            if captureSession.canSetSessionPreset(preset) {
                captureSession.sessionPreset = preset
            }
            
            captureSession.removeInput(oldInput)
            if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
                currentInput = newInput
                position = avPosition

                // Re-apply orientation to the new connection
                if let connection = currentOutput?.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentOrientation
                }
            } else {
                // Rollback
                captureSession.addInput(oldInput)
                captureSession.commitConfiguration()
                throw MoQSessionError.invalidConfiguration("Cannot add new camera input")
            }
            captureSession.commitConfiguration()
        }
    }

    /// Update the capture orientation.
    public func setOrientation(_ orientation: MoQVideoOrientation) {
        let avOrientation = orientation.avOrientation
        queue.async { [self] in
            currentOrientation = avOrientation
            if let connection = currentOutput?.connection(with: .video),
                connection.isVideoOrientationSupported
            {
                connection.videoOrientation = avOrientation
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
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let onFrame, !onFrame(sampleBuffer) {
            self.onFrame = nil
        }
    }
}
