import AVFoundation

/// Built-in microphone capture source for publishing raw PCM audio.
///
/// Your app must include `NSMicrophoneUsageDescription` and configure `AVAudioSession`
/// before starting microphone capture. MoQKit uses the app's audio session as-is.
public final class MicrophoneCapture: NSObject, FrameSource, @unchecked Sendable {
    /// The underlying capture session for advanced configuration if needed.
    public let captureSession = AVCaptureSession()
    private let queue = PublishControl.queue
    /// Advanced frame callback used by ``Publisher``.
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?
    private var currentInput: AVCaptureDeviceInput?
    private var currentOutput: AVCaptureAudioDataOutput?
    private var isConfigured = false
    private var isRunning = false
    let captureLifecycle = CaptureLifecycle()
    private let muteLock = NSLock()
    private var muted = false

    /// Send silence without stopping capture, encoding, or the media track.
    public var isMuted: Bool {
        get { muteLock.lock(); defer { muteLock.unlock() }; return muted }
        set { muteLock.lock(); muted = newValue; muteLock.unlock() }
    }

    private var requestedRunning = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var notificationRun: UUID?

    /// Whether hardware is currently providing frames.
    public var isCapturing: Bool { PublishControl.sync { captureLifecycle.snapshot.running } }


    /// Creates a microphone capture source for the current system input route.
    public override init() {
        super.init()
    }

    /// Starts microphone capture.
    ///
    /// The source captures raw PCM audio and begins forwarding frames once a publisher
    /// track attaches an ``FrameSource/onFrame`` callback.
    public func start() async throws {
        try Task.checkCancellation()
        try await PublishControl.run {
            guard !self.captureLifecycle.snapshot.closed else { throw SessionError.alreadyClosed }
            if self.captureLifecycle.snapshot.running { return }
            KitLogger.publish.info("Microphone capture starting")
            if !self.isConfigured { try self.configureSession() }
            self.installNotifications()
            self.requestedRunning = true
            self.captureSession.startRunning()
            self.isRunning = self.captureSession.isRunning
            guard self.isRunning else {
                self.requestedRunning = false
                throw SessionError.invalidConfiguration("Could not start microphone capture")
            }
            self.captureLifecycle.setRunning(true)
            KitLogger.publish.info("Microphone capture started, generation=\(self.captureLifecycle.snapshot.generation)")
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
        KitLogger.publish.info("Microphone capture stopping, generation=\(self.captureLifecycle.snapshot.generation)")
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
                            KitLogger.publish.error("Microphone capture runtime error: domain=\(error.domain), code=\(error.code), \(error.localizedDescription)")
                        } else {
                            KitLogger.publish.error("Microphone capture runtime error without error details")
                        }
                    }
                    let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                    KitLogger.publish.info("Microphone capture notification=\(notification.name.rawValue), running=\(self.captureSession.isRunning), requested=\(self.requestedRunning), generation=\(self.captureLifecycle.snapshot.generation), interruptionReason=\(String(describing: reason))")
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


    /// Copy PCM storage before silencing; preserve layout, timing, and attachments.
    static func silenced(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var silence: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &silence) == noErr,
            let silence,
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: silence, offsetIntoDestination: 0,
                                      dataLength: length) == noErr else { return nil }
        var copy: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: silence, formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            packetDescriptions: nil, sampleBufferOut: &copy) == noErr, let copy else { return nil }
        CMPropagateAttachments(sample, destination: copy)
        return copy
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
        guard let sample = isMuted ? Self.silenced(sampleBuffer) : sampleBuffer else { return }
        if let onFrame, !onFrame(sample) {
            self.onFrame = nil
        }
    }
}
