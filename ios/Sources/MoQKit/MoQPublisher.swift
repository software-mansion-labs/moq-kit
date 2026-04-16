import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - Public Input Types

/// What to capture for a video track.
public enum MoQVideoInput: Sendable {
    case camera(position: MoQCameraPosition = .back)
    case screen
}

/// Camera position for video capture.
public enum MoQCameraPosition: Sendable {
    case front, back

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

/// What to capture for an audio track.
public enum MoQAudioInput: Sendable {
    case microphone
    case screenAudio
}

// MARK: - Publisher State & Events

/// The lifecycle state of a ``MoQPublisher``.
public enum MoQPublisherState: Sendable, Equatable {
    /// Created, no tracks publishing yet.
    case idle
    /// At least one track is actively sending.
    case publishing
    /// All tracks stopped, broadcast finalized.
    case stopped
    /// An error occurred. The associated string contains a description.
    case error(String)
}

/// Events emitted by ``MoQPublisher`` as tracks start, stop, or encounter errors.
public enum MoQPublisherEvent: Sendable {
    case trackStarted(String)
    case trackStopped(String)
    case error(String, String)
}

// MARK: - Published Track State

/// The lifecycle state of a single published track.
public enum MoQPublishedTrackState: Sendable {
    /// Added but not yet started.
    case idle
    /// Source started, waiting for first encoded frame.
    case starting
    /// Encoding and publishing frames.
    case active
    /// Track finished.
    case stopped
}

// MARK: - MoQPublishedTrack

/// A handle for controlling an individual track's lifecycle.
public final class MoQPublishedTrack: @unchecked Sendable {
    /// The track name.
    public let name: String
    /// A stream of ``MoQPublishedTrackState`` transitions.
    public let state: AsyncStream<MoQPublishedTrackState>

    internal let stateContinuation: AsyncStream<MoQPublishedTrackState>.Continuation
    internal var currentState: MoQPublishedTrackState = .idle
    internal var stopAction: (() -> Void)?

    init(name: String) {
        self.name = name
        var cont: AsyncStream<MoQPublishedTrackState>.Continuation!
        self.state = AsyncStream { cont = $0 }
        self.stateContinuation = cont
        stateContinuation.yield(.idle)
    }

    /// Stop this individual track. Other tracks continue.
    public func stop() {
        guard currentState != .stopped else { return }
        stopAction?()
    }

    internal func transition(to newState: MoQPublishedTrackState) {
        currentState = newState
        stateContinuation.yield(newState)
        if newState == .stopped {
            stateContinuation.finish()
        }
    }

    deinit {
        stateContinuation.finish()
    }
}

// MARK: - Track Descriptors (internal)

/// Describes a video track to be started when `start()` is called.
private struct VideoTrackDescriptor {
    let track: MoQPublishedTrack
    let input: MoQVideoInput
    let config: MoQVideoEncoderConfig
}

/// Describes an audio track to be started when `start()` is called.
private struct AudioTrackDescriptor {
    let track: MoQPublishedTrack
    let input: MoQAudioInput
    let config: MoQAudioEncoderConfig
}

// MARK: - Active Track State (internal)

/// Holds the runtime objects for an active video track.
private final class ActiveVideoTrack {
    var camera: CameraCapture?
    var screenCapture: ScreenCapture?
    var encoder: MoQVideoEncoder?
    var mediaProducer: MoqMediaProducer?
}

/// Holds the runtime objects for an active audio track.
private final class ActiveAudioTrack {
    var microphone: MicrophoneCapture?
    var screenCapture: ScreenCapture?
    var encoder: MoQAudioEncoder?
    var mediaProducer: MoqMediaProducer?
}

// MARK: - MoQPublisher

/// Orchestrates the capture → encode → publish pipeline for a MoQ broadcast.
///
/// Create a publisher, add tracks, then call ``start()`` to begin capturing and
/// encoding. Use ``MoQSession/publish(path:publisher:)`` to register the broadcast
/// with the relay.
///
/// ```swift
/// let publisher = MoQPublisher()
/// let video = publisher.addVideoTrack(input: .camera(position: .back), config: videoConfig)
/// let audio = publisher.addAudioTrack(input: .microphone, config: audioConfig)
/// try session.publish(path: "live/stream", publisher: publisher)
/// try publisher.start()
/// ```
@MainActor
public final class MoQPublisher {
    /// Emits ``MoQPublisherState`` as the publisher transitions through its lifecycle.
    public let state: AsyncStream<MoQPublisherState>
    /// Emits ``MoQPublisherEvent`` values as tracks start, stop, or encounter errors.
    public let events: AsyncStream<MoQPublisherEvent>

    /// The underlying FFI broadcast producer.
    internal let broadcast: MoqBroadcastProducer

    internal let clock = MoQClock()

    private let stateContinuation: AsyncStream<MoQPublisherState>.Continuation
    private let eventsContinuation: AsyncStream<MoQPublisherEvent>.Continuation
    private var currentState: MoQPublisherState = .idle

    // Track descriptors (added before start)
    private var videoDescriptors: [VideoTrackDescriptor] = []
    private var audioDescriptors: [AudioTrackDescriptor] = []

    // Active runtime state
    private var activeVideoTracks: [String: ActiveVideoTrack] = [:]
    private var activeAudioTracks: [String: ActiveAudioTrack] = [:]

    // Shared screen capture instance (video + audio share the same RPScreenRecorder)
    private var sharedScreenCapture: ScreenCapture?

    /// Create a publisher. Does not start publishing until ``start()`` is called.
    public init() throws {
        self.broadcast = try MoqBroadcastProducer()

        var stateCont: AsyncStream<MoQPublisherState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var eventsCont: AsyncStream<MoQPublisherEvent>.Continuation!
        self.events = AsyncStream { eventsCont = $0 }
        self.eventsContinuation = eventsCont

        stateContinuation.yield(.idle)
    }

    /// Add a video track.
    ///
    /// The source and encoder are created and wired automatically when ``start()`` is called.
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"video"`.
    ///   - input: The video capture source.
    ///   - config: Video encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addVideoTrack(
        name: String = "video",
        input: MoQVideoInput,
        config: MoQVideoEncoderConfig = MoQVideoEncoderConfig()
    ) -> MoQPublishedTrack {
        let track = MoQPublishedTrack(name: name)
        videoDescriptors.append(VideoTrackDescriptor(track: track, input: input, config: config))
        return track
    }

    /// Add an audio track.
    ///
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"audio"`.
    ///   - input: The audio capture source.
    ///   - config: Audio encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addAudioTrack(
        name: String = "audio",
        input: MoQAudioInput,
        config: MoQAudioEncoderConfig = MoQAudioEncoderConfig()
    ) -> MoQPublishedTrack {
        let track = MoQPublishedTrack(name: name)
        audioDescriptors.append(AudioTrackDescriptor(track: track, input: input, config: config))
        return track
    }

    /// Start all sources, encoders, and begin publishing.
    ///
    /// Sources are started, and frames flow through encoders into FFI media producers.
    /// The `MoqMediaProducer` for each track is created lazily on the first encoded frame
    /// (because init data is only available after the encoder produces its first output).
    public func start() async throws {
        guard currentState == .idle else {
            throw MoQSessionError.invalidConfiguration("Publisher already started")
        }

        MoQLogger.publish.debug(
            "Starting publisher with \(self.videoDescriptors.count) video + \(self.audioDescriptors.count) audio tracks"
        )

        // Check if we need screen capture (shared across video + audio)
        let needsScreenVideo = videoDescriptors.contains {
            if case .screen = $0.input { return true }
            return false
        }
        let needsScreenAudio = audioDescriptors.contains {
            if case .screenAudio = $0.input { return true }
            return false
        }

        if needsScreenVideo || needsScreenAudio {
            sharedScreenCapture = ScreenCapture()
        }

        // Start video tracks
        for desc in videoDescriptors {
            try await startVideoTrack(desc)
        }

        // Start audio tracks
        for desc in audioDescriptors {
            try await startAudioTrack(desc)
        }

        // Start screen capture if needed (after wiring handlers)
        if needsScreenVideo || needsScreenAudio {
            Task {
                do {
                    try await self.startSharedScreenCapture()
                } catch {
                    MoQLogger.publish.error("Screen capture failed to start: \(error)")
                    self.transition(to: .error("Screen capture failed: \(error)"))
                }
            }
        }

        transition(to: .publishing)
    }

    /// Stop all tracks and finalize the broadcast.
    public func stop() {
        guard currentState == .publishing || currentState == .idle else { return }
        MoQLogger.publish.debug("Stopping publisher")

        for (_, active) in activeVideoTracks {
            active.camera?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        activeVideoTracks.removeAll()

        for (_, active) in activeAudioTracks {
            active.microphone?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        activeAudioTracks.removeAll()

        if let screenCapture = sharedScreenCapture {
            Task { await screenCapture.stop() }
            sharedScreenCapture = nil
        }

        try? broadcast.finish()
        clock.reset()

        // Transition all tracks to stopped
        for desc in videoDescriptors {
            desc.track.transition(to: .stopped)
            eventsContinuation.yield(.trackStopped(desc.track.name))
        }
        for desc in audioDescriptors {
            desc.track.transition(to: .stopped)
            eventsContinuation.yield(.trackStopped(desc.track.name))
        }

        transition(to: .stopped)
        stateContinuation.finish()
        eventsContinuation.finish()
    }

    deinit {
        // Best-effort cleanup
        for (_, active) in activeVideoTracks {
            active.camera?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        for (_, active) in activeAudioTracks {
            active.microphone?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        try? broadcast.finish()
        stateContinuation.finish()
        eventsContinuation.finish()
    }

    // MARK: - Private: State

    private func transition(to newState: MoQPublisherState) {
        MoQLogger.publish.debug(
            "Publisher state: \(String(describing: self.currentState)) → \(String(describing: newState))"
        )
        currentState = newState
        stateContinuation.yield(newState)
    }

    // MARK: - Private: Video Track Wiring

    private func startVideoTrack(_ desc: VideoTrackDescriptor) async throws {
        let active = ActiveVideoTrack()
        let encoder = MoQVideoEncoder(config: desc.config)
        active.encoder = encoder

        let trackHandle = desc.track
        let clock = self.clock
        let broadcast = self.broadcast
        let eventsContinuation = self.eventsContinuation
        let formatString = desc.config.format

        // Encoder output: lazily creates MoqMediaProducer on first keyframe with init data
        try encoder.start { [weak active] frame in
            guard let active else { return }

            // Create the FFI media producer on first keyframe (when init data is available)
            if active.mediaProducer == nil {
                guard let initData = frame.initData else { return }
                do {
                    let producer = try broadcast.publishMedia(format: formatString, init: initData)
                    active.mediaProducer = producer
                    MoQLogger.publish.debug(
                        "Video track '\(trackHandle.name)' media producer created")
                    Task { @MainActor in
                        trackHandle.transition(to: .active)
                        eventsContinuation.yield(.trackStarted(trackHandle.name))
                    }
                } catch {
                    MoQLogger.publish.error("Failed to create video media producer: \(error)")
                    Task { @MainActor in
                        trackHandle.transition(to: .stopped)
                        eventsContinuation.yield(
                            .error(trackHandle.name, error.localizedDescription))
                    }
                    return
                }
            }

            let timestampUs = clock.timestampUs(from: frame.presentationTime)
            do {
                try active.mediaProducer?.writeFrame(payload: frame.data, timestampUs: timestampUs)
            } catch {
                MoQLogger.publish.error("Failed to write video frame: \(error)")
            }
        }

        trackHandle.transition(to: .starting)

        // Wire source → encoder
        switch desc.input {
        case .camera(let position):
            let camera = CameraCapture(
                position: position.avPosition,
                width: desc.config.width,
                height: desc.config.height
            )
            active.camera = camera
            try await camera.start { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer)
            }

        case .screen:
            // Screen capture is started separately via shared instance
            // Wire the video handler when screen capture starts
            active.screenCapture = sharedScreenCapture
        }

        // Set up individual track stop
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.camera?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
            self.activeVideoTracks.removeValue(forKey: trackHandle.name)
            trackHandle.transition(to: .stopped)
            self.eventsContinuation.yield(.trackStopped(trackHandle.name))
            self.checkAllTracksStopped()
        }

        activeVideoTracks[desc.track.name] = active
    }

    // MARK: - Private: Audio Track Wiring

    private func startAudioTrack(_ desc: AudioTrackDescriptor) async throws {
        let active = ActiveAudioTrack()
        let encoder = MoQAudioEncoder(config: desc.config)
        active.encoder = encoder

        let trackHandle = desc.track
        let clock = self.clock
        let broadcast = self.broadcast
        let eventsContinuation = self.eventsContinuation
        let formatString = desc.config.format

        // Encoder output
        try encoder.start { [weak active] frame in
            guard let active else { return }

            if active.mediaProducer == nil {
                guard let initData = frame.initData else { return }
                do {
                    let producer = try broadcast.publishMedia(format: formatString, init: initData)
                    active.mediaProducer = producer
                    MoQLogger.publish.debug(
                        "Audio track '\(trackHandle.name)' media producer created")
                    Task { @MainActor in
                        trackHandle.transition(to: .active)
                        eventsContinuation.yield(.trackStarted(trackHandle.name))
                    }
                } catch {
                    MoQLogger.publish.error("Failed to create audio media producer: \(error)")
                    Task { @MainActor in
                        trackHandle.transition(to: .stopped)
                        eventsContinuation.yield(
                            .error(trackHandle.name, error.localizedDescription))
                    }
                    return
                }
            }

            let timestampUs = clock.timestampUs(from: frame.presentationTime)
            do {
                MoQLogger.publish.warning("Writing frame")
                try active.mediaProducer?.writeFrame(payload: frame.data, timestampUs: timestampUs)
            } catch {
                MoQLogger.publish.error("Failed to write audio frame: \(error)")
            }
        }

        trackHandle.transition(to: .starting)

        // Wire source → encoder
        switch desc.input {
        case .microphone:
            let mic = MicrophoneCapture()
            active.microphone = mic
            try await mic.start { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer)
            }

        case .screenAudio:
            active.screenCapture = sharedScreenCapture
        }

        // Set up individual track stop
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.microphone?.stop()
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
            self.activeAudioTracks.removeValue(forKey: trackHandle.name)
            trackHandle.transition(to: .stopped)
            self.eventsContinuation.yield(.trackStopped(trackHandle.name))
            self.checkAllTracksStopped()
        }

        activeAudioTracks[desc.track.name] = active
    }

    // MARK: - Private: Screen Capture

    private func startSharedScreenCapture() async throws {
        guard let screenCapture = sharedScreenCapture else { return }

        // Find the video encoder for screen video
        let screenVideoEncoder =
            videoDescriptors
            .first {
                if case .screen = $0.input { return true }
                return false
            }
            .flatMap { activeVideoTracks[$0.track.name]?.encoder }

        // Find the audio encoder for screen audio
        let screenAudioEncoder =
            audioDescriptors
            .first {
                if case .screenAudio = $0.input { return true }
                return false
            }
            .flatMap { activeAudioTracks[$0.track.name]?.encoder }

        let videoHandler: (CMSampleBuffer) -> Void = { [weak screenVideoEncoder] sampleBuffer in
            screenVideoEncoder?.encode(sampleBuffer)
        }

        let audioHandler: ((CMSampleBuffer) -> Void)? = screenAudioEncoder.map { encoder in
            return { [weak encoder] sampleBuffer in
                encoder?.encode(sampleBuffer)
            }
        }

        try await screenCapture.start(videoHandler: videoHandler, audioHandler: audioHandler)
    }

    // MARK: - Private: Lifecycle

    private func checkAllTracksStopped() {
        if activeVideoTracks.isEmpty && activeAudioTracks.isEmpty && currentState == .publishing {
            transition(to: .stopped)
            stateContinuation.finish()
            eventsContinuation.finish()
        }
    }
}
