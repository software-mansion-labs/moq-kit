import AVFoundation

/// Camera position for video capture.
public enum CameraPosition: Sendable {
    /// Front-facing camera, when available.
    case front
    /// Rear-facing camera, when available.
    case back

    var position: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

/// Video capture orientation.
public enum VideoOrientation: Sendable {
    /// Portrait orientation with the device upright.
    case portrait
    /// Portrait orientation with the device upside down.
    case portraitUpsideDown
    /// Landscape with the device rotated to the right.
    case landscapeRight
    /// Landscape with the device rotated to the left.
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

/// Camera device selection and preferred capture settings.
public struct Camera: Sendable {
    /// Which camera to use.
    public let position: CameraPosition
    /// Preferred coded frame width in pixels.
    public let width: Int32
    /// Preferred coded frame height in pixels.
    public let height: Int32
    /// Preferred orientation for captured frames.
    public let orientation: VideoOrientation

    /// Creates a camera configuration for ``CameraCapture``.
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

/// Built-in camera capture source for publishing video.
///
/// `CameraCapture` owns an `AVCaptureSession` and forwards frames into a publisher track.
/// You can also reuse its ``captureSession`` for a local preview UI. Your app must include
/// `NSCameraUsageDescription` and should call ``start()`` before expecting frames to reach
/// a publisher.
public final class CameraCapture: NSObject, FrameSource, @unchecked Sendable {
    /// The underlying capture session, exposed for preview UI or advanced camera setup.
    public let captureSession = AVCaptureSession()
    private let queue = PublishControl.queue
    /// Advanced frame callback used by ``Publisher``.
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    /// The currently configured camera settings.
    public private(set) var camera: Camera
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false
    private var isRunning = false
    let captureLifecycle = CaptureLifecycle()
    private var requestedRunning = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var notificationRun: UUID?

    /// Whether hardware is currently providing frames.
    public var isCapturing: Bool { PublishControl.sync { captureLifecycle.snapshot.running } }


    /// Creates a camera capture source with the requested device and format preferences.
    public init(camera: Camera = Camera()) {
        self.camera = camera
        super.init()
    }

    /// Starts the capture session.
    ///
    /// The session is configured on an internal queue. After this succeeds, frames begin
    /// arriving through ``FrameSource/onFrame`` when a publisher track is attached.
    public func start() async throws {
        try Task.checkCancellation()
        try await PublishControl.run {
            guard !self.captureLifecycle.snapshot.closed else { throw SessionError.alreadyClosed }
            if self.captureLifecycle.snapshot.running { return }
            KitLogger.publish.info("Camera capture starting")
            if !self.isConfigured { try self.configureSession() }
            self.installNotifications()
            self.requestedRunning = true
            self.captureSession.startRunning()
            self.isRunning = self.captureSession.isRunning
            guard self.isRunning else {
                self.requestedRunning = false
                throw SessionError.invalidConfiguration("Could not start camera capture")
            }
            self.captureLifecycle.setRunning(true)
            KitLogger.publish.info("Camera capture started, generation=\(self.captureLifecycle.snapshot.generation)")
        }
        if Task.isCancelled {
            await stop()
            throw CancellationError()
        }
    }

    /// Release hardware and await attached publication teardown. This object can restart.
    public func stop() async {
        await PublishControl.finish { self.stopOwned() }
    }

    /// Permanently dispose this capture and its publication attachment.
    public func close() async {
        await PublishControl.finish {
            self.stopOwned()
            self.captureLifecycle.close()
            self.resetSession()
            self.removeNotifications()
        }
    }

    private func stopOwned() {
        KitLogger.publish.info("Camera capture stopping, generation=\(self.captureLifecycle.snapshot.generation)")
        requestedRunning = false
        notificationRun = nil
        removeNotifications()
        captureLifecycle.setRunning(false)
        if captureSession.isRunning { captureSession.stopRunning() }
        isRunning = false
    }

    private func installNotifications() {
        guard notificationTokens.isEmpty else { return }
        let run = UUID()
        notificationRun = run
        let names: [Notification.Name] = [
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.didStopRunningNotification,
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.interruptionEndedNotification,
            AVCaptureSession.didStartRunningNotification,
        ]
        notificationTokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: captureSession, queue: nil) {
                [weak self] notification in
                PublishControl.queue.async { [weak self] in
                    guard let self, self.notificationRun == run else { return }
                    if notification.name == AVCaptureSession.runtimeErrorNotification {
                        if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                            KitLogger.publish.error("Camera capture runtime error: domain=\(error.domain), code=\(error.code), \(error.localizedDescription)")
                        } else {
                            KitLogger.publish.error("Camera capture runtime error without error details")
                        }
                    }
                    let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                    KitLogger.publish.info("Camera capture notification=\(notification.name.rawValue), running=\(self.captureSession.isRunning), requested=\(self.requestedRunning), generation=\(self.captureLifecycle.snapshot.generation), interruptionReason=\(String(describing: reason))")
                    guard self.requestedRunning else { return }
                    let available = notification.name == AVCaptureSession.interruptionEndedNotification
                        || notification.name == AVCaptureSession.didStartRunningNotification
                    self.captureLifecycle.setRunning(available && self.captureSession.isRunning)
                }
            }
        }
    }

    private func removeNotifications() {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }

    deinit {
        PublishControl.sync {
            stopOwned()
            captureLifecycle.close()
            removeNotifications()
        }
    }

    /// Switches to a different camera device or capture configuration while running.
    ///
    /// Use this for front/back camera changes or resolution/orientation updates without
    /// recreating the capture source.
    public func `switch`(to newCamera: Camera) throws {
        try PublishControl.sync {
            guard !captureLifecycle.snapshot.closed else { throw SessionError.alreadyClosed }
            guard requestedRunning, isConfigured else {
                resetSession()
                camera = newCamera
                return
            }

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

    private func configureSession() throws {
        captureSession.beginConfiguration()
        do {
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
            isConfigured = true
        } catch {
            captureSession.commitConfiguration()
            resetSession()
            throw error
        }
    }

    private func resetSession() {
        captureLifecycle.setRunning(false)
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

    private func sessionPreset(for width: Int32, height: Int32) -> AVCaptureSession.Preset {
        let pixels = Int(width) * Int(height)
        if pixels <= 640 * 480 { return .vga640x480 }
        if pixels <= 1280 * 720 { return .hd1280x720 }
        if pixels <= 1920 * 1080 { return .hd1920x1080 }
        return .hd4K3840x2160
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// AVFoundation delegate callback used internally to forward captured frames.
    ///
    /// Apps normally do not call this directly.
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
