import AVFoundation

/// Camera position for video capture.
public enum CameraPosition: Sendable {
    case front, back

    var position: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

/// Video capture orientation.
public enum VideoOrientation: Sendable {
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

/// Camera device identity and capture configuration.
public struct Camera: Sendable {
    public let position: CameraPosition
    public let width: Int32
    public let height: Int32
    public let orientation: VideoOrientation

    public init(
        position: CameraPosition = .back,
        width: Int32 = 720,
        height: Int32 = 1280,
        orientation: VideoOrientation = .portrait
    ) {
        self.position = position
        self.width = width
        self.height = height
        self.orientation = orientation
    }
}

/// Wraps `AVCaptureSession` to capture video frames from a camera device.
public final class CameraCapture: NSObject, FrameSource, @unchecked Sendable {
    public let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.CameraCapture")
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    public private(set) var camera: Camera
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureVideoDataOutput?

    public init(camera: Camera = Camera()) {
        self.camera = camera
        super.init()
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    captureSession.beginConfiguration()

                    let preset = sessionPreset(for: camera.width, height: camera.height)
                    if captureSession.canSetSessionPreset(preset) {
                        captureSession.sessionPreset = preset
                    }

                    guard
                        let device = AVCaptureDevice.default(
                            .builtInWideAngleCamera, for: .video, position: camera.position.position
                        )
                    else {
                        throw SessionError.invalidConfiguration(
                            "No camera available for position \(camera.position.position)")
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard captureSession.canAddInput(input) else {
                        throw SessionError.invalidConfiguration("Cannot add camera input")
                    }
                    captureSession.addInput(input)
                    currentInput = input

                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)

                    guard captureSession.canAddOutput(output) else {
                        throw SessionError.invalidConfiguration("Cannot add video output")
                    }
                    captureSession.addOutput(output)
                    currentOutput = output

                    if let connection = output.connection(with: .video),
                       connection.isVideoOrientationSupported {
                        connection.videoOrientation = camera.orientation.avOrientation
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

    /// Switch camera device and/or configuration while the session is running.
    public func `switch`(to newCamera: Camera) throws {
        try queue.sync {
            guard let oldInput = currentInput else {
                throw SessionError.invalidConfiguration("No current camera input")
            }
            guard
                let device = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: newCamera.position.position
                )
            else {
                throw SessionError.invalidConfiguration(
                    "No camera available for position \(newCamera.position.position)")
            }

            let newInput = try AVCaptureDeviceInput(device: device)

            captureSession.beginConfiguration()

            let preset = sessionPreset(for: newCamera.width, height: newCamera.height)
            if captureSession.canSetSessionPreset(preset) {
                captureSession.sessionPreset = preset
            }

            captureSession.removeInput(oldInput)
            if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
                currentInput = newInput
                camera = newCamera

                if let connection = currentOutput?.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = newCamera.orientation.avOrientation
                }
            } else {
                captureSession.addInput(oldInput)
                captureSession.commitConfiguration()
                throw SessionError.invalidConfiguration("Cannot add new camera input")
            }
            captureSession.commitConfiguration()
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
