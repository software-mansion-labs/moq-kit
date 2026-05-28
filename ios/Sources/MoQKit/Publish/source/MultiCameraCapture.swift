#if os(iOS)

import AVFoundation

/// Built-in multi-camera capture source for publishing front and back cameras concurrently.
///
/// `MultiCameraCapture` owns an `AVCaptureMultiCamSession` and forwards each camera into
/// a separate frame source. Use ``frontSource`` and ``backSource`` as independent
/// ``Publisher/addVideoTrack(name:source:config:)`` inputs. Your app must include
/// `NSCameraUsageDescription` and should check ``isSupported`` before offering this mode.
public final class MultiCameraCapture: NSObject, @unchecked Sendable {
    /// Whether the current device can run `AVCaptureMultiCamSession`.
    public static var isSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    /// The underlying multi-camera capture session, exposed for advanced preview UI.
    public let captureSession = AVCaptureMultiCamSession()
    /// Video frames produced by the front-facing camera.
    public let frontSource = FrameRelay()
    /// Video frames produced by the rear-facing camera.
    public let backSource = FrameRelay()

    /// Requested front camera settings.
    public let front: Camera
    /// Requested back camera settings.
    public let back: Camera
    /// Maximum frame rate requested for both cameras.
    public let maxFrameRate: Double

    private let queue = DispatchQueue(label: "com.swmansion.MoQKit.MultiCameraCapture")
    private var frontOutput: AVCaptureVideoDataOutput?
    private var backOutput: AVCaptureVideoDataOutput?
    private var configuredInputs: [AVCaptureDeviceInput] = []
    private var configuredOutputs: [AVCaptureOutput] = []
    private var isConfigured = false
    private var isRunning = false

    /// Creates a multi-camera capture source for simultaneous front and back video.
    public init(
        front: Camera = Camera(position: .front),
        back: Camera = Camera(position: .back),
        maxFrameRate: Double = 30
    ) {
        self.front = front
        self.back = back
        self.maxFrameRate = maxFrameRate
        super.init()
    }

    /// Starts the multi-camera capture session.
    ///
    /// The session is configured on an internal queue. After this succeeds, frames begin
    /// arriving through ``frontSource`` and ``backSource`` when publisher tracks attach.
    public func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard Self.isSupported else {
                        throw SessionError.invalidConfiguration(
                            "Multi-camera capture is not supported on this device")
                    }
                    guard maxFrameRate > 0 else {
                        throw SessionError.invalidConfiguration(
                            "Multi-camera frame rate must be greater than zero")
                    }

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

    /// Stops multi-camera capture and detaches active frame consumers.
    public func stop() {
        queue.async { [self] in
            if isRunning {
                captureSession.stopRunning()
                isRunning = false
            }
        }
        frontSource.onFrame = nil
        backSource.onFrame = nil
    }

    private func configureSession() throws {
        var addedInputs: [AVCaptureDeviceInput] = []
        var addedOutputs: [AVCaptureOutput] = []

        captureSession.beginConfiguration()
        do {
            let frontPipeline = try configureCamera(front, route: .front)
            addedInputs.append(frontPipeline.input)
            addedOutputs.append(frontPipeline.output)

            let backPipeline = try configureCamera(back, route: .back)
            addedInputs.append(backPipeline.input)
            addedOutputs.append(backPipeline.output)

            guard captureSession.hardwareCost <= 1 else {
                throw SessionError.invalidConfiguration(
                    "Multi-camera hardware cost exceeds the device budget")
            }
            guard captureSession.systemPressureCost <= 1 else {
                throw SessionError.invalidConfiguration(
                    "Multi-camera system pressure cost exceeds the sustainable budget")
            }

            captureSession.commitConfiguration()
            configuredInputs = addedInputs
            configuredOutputs = addedOutputs
            isConfigured = true
        } catch {
            captureSession.commitConfiguration()
            removeSession(inputs: addedInputs, outputs: addedOutputs)
            frontOutput = nil
            backOutput = nil
            throw error
        }
    }

    private func removeSession(inputs: [AVCaptureDeviceInput], outputs: [AVCaptureOutput]) {
        captureSession.beginConfiguration()
        for output in outputs {
            captureSession.removeOutput(output)
        }
        for input in inputs {
            captureSession.removeInput(input)
        }
        captureSession.commitConfiguration()
    }

    private func configureCamera(
        _ camera: Camera,
        route: CameraRoute
    ) throws -> (input: AVCaptureDeviceInput, output: AVCaptureVideoDataOutput) {
        var addedInput: AVCaptureDeviceInput?
        var addedOutput: AVCaptureVideoDataOutput?

        do {
            return try configureCameraPipeline(
                camera,
                route: route,
                addedInput: &addedInput,
                addedOutput: &addedOutput
            )
        } catch {
            if let addedOutput {
                captureSession.removeOutput(addedOutput)
            }
            if let addedInput {
                captureSession.removeInput(addedInput)
            }
            throw error
        }
    }

    private func configureCameraPipeline(
        _ camera: Camera,
        route: CameraRoute,
        addedInput: inout AVCaptureDeviceInput?,
        addedOutput: inout AVCaptureVideoDataOutput?
    ) throws -> (input: AVCaptureDeviceInput, output: AVCaptureVideoDataOutput) {
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: camera.position.position
            )
        else {
            throw SessionError.invalidConfiguration(
                "No camera available for position \(camera.position.position)")
        }

        try configureActiveFormat(for: device, camera: camera)

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw SessionError.invalidConfiguration(
                "Cannot add multi-camera input for position \(camera.position.position)")
        }
        captureSession.addInputWithNoConnections(input)
        addedInput = input

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard captureSession.canAddOutput(output) else {
            throw SessionError.invalidConfiguration(
                "Cannot add multi-camera output for position \(camera.position.position)")
        }
        captureSession.addOutputWithNoConnections(output)
        addedOutput = output

        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            throw SessionError.invalidConfiguration(
                "No video port available for position \(camera.position.position)")
        }

        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard captureSession.canAddConnection(connection) else {
            throw SessionError.invalidConfiguration(
                "Cannot connect multi-camera output for position \(camera.position.position)")
        }
        captureSession.addConnection(connection)

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = camera.orientation.avOrientation
        }

        switch route {
        case .front:
            frontOutput = output
        case .back:
            backOutput = output
        }

        return (input, output)
    }

    private func configureActiveFormat(for device: AVCaptureDevice, camera: Camera) throws {
        let selectedFormat = try selectFormat(for: device, camera: camera)
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, maxFrameRate.rounded()))
        )

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selectedFormat
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }

    private func selectFormat(
        for device: AVCaptureDevice,
        camera: Camera
    ) throws -> AVCaptureDevice.Format {
        let targetWidth = Int(camera.width)
        let targetHeight = Int(camera.height)
        let targetPixels = targetWidth * targetHeight

        let candidates = device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= maxFrameRate && maxFrameRate <= range.maxFrameRate
            }
        }

        guard !candidates.isEmpty else {
            throw SessionError.invalidConfiguration(
                "No multi-camera format supports \(Int(maxFrameRate)) fps for \(device.localizedName)")
        }

        return candidates.min { lhs, rhs in
            let lhsScore = formatScore(lhs, targetPixels: targetPixels)
            let rhsScore = formatScore(rhs, targetPixels: targetPixels)
            if lhsScore.pixelPenalty != rhsScore.pixelPenalty {
                return lhsScore.pixelPenalty < rhsScore.pixelPenalty
            }
            return lhsScore.maxFrameRate < rhsScore.maxFrameRate
        }!
    }

    private func formatScore(
        _ format: AVCaptureDevice.Format,
        targetPixels: Int
    ) -> (pixelPenalty: Int, maxFrameRate: Double) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let pixels = Int(dimensions.width) * Int(dimensions.height)
        let pixelPenalty = abs(pixels - targetPixels)
        let maxFrameRate = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 0
        return (pixelPenalty, maxFrameRate)
    }

    private enum CameraRoute {
        case front
        case back
    }
}

extension MultiCameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// AVFoundation delegate callback used internally to forward captured frames.
    ///
    /// Apps normally do not call this directly.
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === frontOutput {
            if !frontSource.send(sampleBuffer) {
                frontSource.onFrame = nil
            }
        } else if output === backOutput {
            if !backSource.send(sampleBuffer) {
                backSource.onFrame = nil
            }
        }
    }
}

#endif
