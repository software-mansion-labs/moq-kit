import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - Publisher State & Events

/// The lifecycle state of a ``Publisher``.
public enum PublisherState: Sendable, Equatable {
    /// Created, no tracks publishing yet.
    case idle
    /// At least one track is actively sending.
    case publishing
    /// All tracks stopped, broadcast finalized.
    case stopped
    /// An error occurred. The associated string contains a description.
    case error(String)
}

/// Events emitted by ``Publisher`` as tracks start, stop, or encounter errors.
public enum PublisherEvent: Sendable {
    /// A track started producing publishable output. Associated value: track name.
    case trackStarted(String)
    /// A track stopped publishing. Associated value: track name.
    case trackStopped(String)
    /// A track failed. Associated values: track name, human-readable error message.
    case error(String, String)
}

// MARK: - Published Track State

/// The lifecycle state of a single published track.
public enum PublishedTrackState: Sendable {
    /// Added but not yet started.
    case idle
    /// Source started, waiting for first encoded frame.
    case starting
    /// Encoding and publishing frames.
    case active
    /// Track finished.
    case stopped
}

// MARK: - Track Codec Info

/// Codec information associated with a published track.
public enum TrackCodecInfo: Sendable {
    /// Video codec plus basic format information.
    case video(codec: VideoCodec, width: Int32, height: Int32, frameRate: Double)
    /// Audio codec plus sample-rate information.
    case audio(codec: AudioCodec, sampleRate: Double)
    /// App-defined object/data track.
    case data
}

// MARK: - PublishedTrack

/// Handle returned when you add a track to a publisher.
///
/// Use `PublishedTrack` to observe per-track state or stop one track without stopping
/// the entire publisher.
public final class PublishedTrack: @unchecked Sendable {
    /// The track name.
    public let name: String
    /// Codec information for the track.
    public let codecInfo: TrackCodecInfo
    /// A stream of ``PublishedTrackState`` transitions.
    public let state: AsyncStream<PublishedTrackState>

    internal let stateContinuation: AsyncStream<PublishedTrackState>.Continuation
    internal var currentState: PublishedTrackState = .idle
    internal var stopAction: (() -> Void)?

    init(name: String, codecInfo: TrackCodecInfo) {
        self.name = name
        self.codecInfo = codecInfo
        var cont: AsyncStream<PublishedTrackState>.Continuation!
        self.state = AsyncStream { cont = $0 }
        self.stateContinuation = cont
        stateContinuation.yield(.idle)
    }

    /// Stops this track only.
    ///
    /// Other tracks continue publishing. If this was the last active track, the publisher
    /// transitions to ``PublisherState/stopped``.
    public func stop() {
        guard currentState != .stopped else { return }
        stopAction?()
    }

    internal func transition(to newState: PublishedTrackState) {
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
    let track: PublishedTrack
    let source: any FrameSource
    let config: VideoEncoderConfig
}

/// Describes an audio track to be started when `start()` is called.
private struct AudioTrackDescriptor {
    let track: PublishedTrack
    let source: any FrameSource
    let config: AudioEncoderConfig
}

/// Describes an object track to be started when `start()` is called.
private struct DataTrackDescriptor {
    let track: PublishedTrack
    let emitter: DataTrackEmitter
}

// MARK: - Active Track State (internal)

/// Holds the runtime objects for an active video track.
private final class VideoTrack {
    var source: (any FrameSource)?
    var encoder: VideoEncoder?
    var mediaProducer: MoqMediaProducer?
}

/// Holds the runtime objects for an active audio track.
private final class AudioTrack {
    var source: (any FrameSource)?
    var encoder: AudioEncoder?
    var mediaProducer: MoqMediaProducer?
}

/// Holds the runtime objects for an active object track.
private final class DataTrack {
    var emitter: DataTrackEmitter?
    var producer: MoqTrackProducer?
}

// MARK: - Publisher

/// Orchestrates publishing one MoQ broadcast.
///
/// Typical setup is:
///
/// 1. Start any capture sources your app owns, such as ``CameraCapture`` or
///    ``MicrophoneCapture``.
/// 2. Create a publisher and add one or more video, audio, or data tracks.
/// 3. Register the publisher with ``Session/publish(path:publisher:)``.
/// 4. Call ``start()`` to begin encoding and sending frames.
///
/// ```swift
/// let camera = CameraCapture(camera: Camera(position: .back, width: 1920, height: 1080))
/// try await camera.start()
///
/// let publisher = try Publisher()
/// let video = publisher.addVideoTrack(name: "video", source: camera)
/// try session.publish(path: "live/stream", publisher: publisher)
/// try await publisher.start()
/// ```
///
/// A `Publisher` is single-use. After ``stop()`` completes, create a new instance for the
/// next broadcast.
public final class Publisher {
    /// Emits ``PublisherState`` values for the lifetime of the publisher.
    public let state: AsyncStream<PublisherState>
    /// Emits ``PublisherEvent`` values as tracks start, stop, or fail.
    public let events: AsyncStream<PublisherEvent>

    /// The underlying FFI broadcast producer.
    internal let broadcast: MoqBroadcastProducer

    internal let clock = Clock()

    private let stateContinuation: AsyncStream<PublisherState>.Continuation
    private let eventsContinuation: AsyncStream<PublisherEvent>.Continuation
    private var currentState: PublisherState = .idle

    // Track descriptors (added before start)
    private var videoDescriptors: [VideoTrackDescriptor] = []
    private var audioDescriptors: [AudioTrackDescriptor] = []
    private var datatDescriptors: [DataTrackDescriptor] = []

    // Active runtime state
    private var activeVideoTracks: [String: VideoTrack] = [:]
    private var activeAudioTracks: [String: AudioTrack] = [:]
    private var activeDataTracks: [String: DataTrack] = [:]

    /// Create a publisher. Does not start publishing until ``start()`` is called.
    public init() throws {
        self.broadcast = try MoqBroadcastProducer()

        var stateCont: AsyncStream<PublisherState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var eventsCont: AsyncStream<PublisherEvent>.Continuation!
        self.events = AsyncStream { eventsCont = $0 }
        self.eventsContinuation = eventsCont

        stateContinuation.yield(.idle)
    }

    /// Adds a video track backed by a frame source.
    ///
    /// The publisher creates and attaches the encoder when ``start()`` is called. Starting
    /// the capture source itself remains the app's responsibility.
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"video"`.
    ///   - source: A frame source that produces video sample buffers.
    ///   - config: Video encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addVideoTrack(
        name: String = "video",
        source: any FrameSource,
        config: VideoEncoderConfig = VideoEncoderConfig()
    ) -> PublishedTrack {
        let track = PublishedTrack(
            name: name,
            codecInfo: .video(
                codec: config.codec, width: config.width, height: config.height,
                frameRate: config.maxFrameRate))
        videoDescriptors.append(VideoTrackDescriptor(track: track, source: source, config: config))
        return track
    }

    /// Adds an audio track backed by a frame source.
    ///
    /// Starting the capture source itself remains the app's responsibility.
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"audio"`.
    ///   - source: A frame source that produces audio sample buffers.
    ///   - config: Audio encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addAudioTrack(
        name: String = "audio",
        source: any FrameSource,
        config: AudioEncoderConfig = AudioEncoderConfig()
    ) -> PublishedTrack {
        let track = PublishedTrack(
            name: name,
            codecInfo: .audio(codec: config.codec, sampleRate: config.sampleRate))
        audioDescriptors.append(AudioTrackDescriptor(track: track, source: source, config: config))
        return track
    }

    /// Adds a data track for app-defined binary payloads.
    ///
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"data"`.
    ///   - source: Emitter the app uses to push objects after ``start()`` succeeds.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addDataTrack(
        name: String = "data",
        source: DataTrackEmitter
    ) -> PublishedTrack {
        let track = PublishedTrack(name: name, codecInfo: .data)
        datatDescriptors.append(DataTrackDescriptor(track: track, emitter: source))
        return track
    }

    /// Starts publishing all registered tracks.
    ///
    /// Call ``Session/publish(path:publisher:)`` before this method. `start()` does not
    /// start `CameraCapture`, `MicrophoneCapture`, or any custom source for you; it only
    /// binds those sources to encoders and the relay-facing producers.
    public func start() async throws {
        guard currentState == .idle else {
            throw SessionError.invalidConfiguration("Publisher already started")
        }

        KitLogger.publish.debug(
            "Starting publisher with \(self.videoDescriptors.count) video + \(self.audioDescriptors.count) audio tracks"
        )

        try validateCodecSupport()

        // Start video tracks
        for desc in videoDescriptors {
            try startVideoTrack(desc)
        }

        // Start audio tracks
        for desc in audioDescriptors {
            try startAudioTrack(desc)
        }

        // Start object tracks
        for desc in datatDescriptors {
            try startObjectTrack(desc)
        }

        transition(to: .publishing)
    }

    /// Stops all tracks and finalizes the broadcast.
    ///
    /// After calling this, the publisher cannot be started again.
    public func stop() {
        guard currentState == .publishing || currentState == .idle else { return }
        KitLogger.publish.debug("Stopping publisher")

        for (_, active) in activeVideoTracks {
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        activeVideoTracks.removeAll()

        for (_, active) in activeAudioTracks {
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        activeAudioTracks.removeAll()

        for (_, active) in activeDataTracks {
            active.emitter?.detach()
        }
        activeDataTracks.removeAll()

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
        for desc in datatDescriptors {
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
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        for (_, active) in activeAudioTracks {
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
        }
        for (_, active) in activeDataTracks {
            active.emitter?.detach()
        }
        try? broadcast.finish()
        stateContinuation.finish()
        eventsContinuation.finish()
    }

    // MARK: - Private: State

    private func transition(to newState: PublisherState) {
        KitLogger.publish.debug(
            "Publisher state: \(String(describing: self.currentState)) → \(String(describing: newState))"
        )
        currentState = newState
        stateContinuation.yield(newState)
    }

    // MARK: - Private: Video Track Wiring

    private func validateCodecSupport() throws {
        for desc in videoDescriptors {
            if let reason = desc.config.unsupportedReason {
                throw SessionError.unsupportedCodec(
                    "Video track '\(desc.track.name)' is not supported: \(reason)")
            }
        }

        for desc in audioDescriptors {
            if let reason = desc.config.unsupportedReason {
                throw SessionError.unsupportedCodec(
                    "Audio track '\(desc.track.name)' is not supported: \(reason)")
            }
        }
    }

    private func startVideoTrack(_ desc: VideoTrackDescriptor) throws {
        let active = VideoTrack()
        let encoder = VideoEncoder(config: desc.config)
        active.encoder = encoder
        active.source = desc.source

        let trackHandle = desc.track
        let clock = self.clock
        let broadcast = self.broadcast
        let eventsContinuation = self.eventsContinuation
        let formatString = desc.config.format

        // Encoder output: lazily creates the media producer on the first keyframe
        // that carries init data (parameter sets), then writes frames to it.
        try encoder.start { [weak active] frame in
            guard let active else { return }

            if active.mediaProducer == nil {
                guard let initData = frame.initData else { return }
                do {
                    let producer = try broadcast.publishMedia(format: formatString, init: initData)
                    active.mediaProducer = producer
                    KitLogger.publish.debug(
                        "Video track '\(trackHandle.name)' media producer created")
                    Task { @MainActor in
                        trackHandle.transition(to: .active)
                        eventsContinuation.yield(.trackStarted(trackHandle.name))
                    }
                } catch {
                    KitLogger.publish.error("Failed to create video media producer: \(error)")
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
                KitLogger.publish.error("Failed to write video frame: \(error)")
            }
        }

        trackHandle.transition(to: .starting)

        // Bind source → encoder
        desc.source.onFrame = { [weak encoder] sampleBuffer in
            guard let encoder else { return false }
            encoder.encode(sampleBuffer)
            return true
        }

        // Set up individual track stop
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
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

    private func startAudioTrack(_ desc: AudioTrackDescriptor) throws {
        let active = AudioTrack()
        let encoder = AudioEncoder(config: desc.config)
        active.encoder = encoder
        active.source = desc.source

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
                    KitLogger.publish.debug(
                        "Audio track '\(trackHandle.name)' media producer created")
                    Task { @MainActor in
                        trackHandle.transition(to: .active)
                        eventsContinuation.yield(.trackStarted(trackHandle.name))
                    }
                } catch {
                    KitLogger.publish.error("Failed to create audio media producer: \(error)")
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
                KitLogger.publish.error("Failed to write audio frame: \(error)")
            }
        }

        trackHandle.transition(to: .starting)

        // Bind source → encoder
        desc.source.onFrame = { [weak encoder] sampleBuffer in
            guard let encoder else { return false }
            encoder.encode(sampleBuffer)
            return true
        }

        // Set up individual track stop
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.source?.onFrame = { (_: CMSampleBuffer) in false }
            active.encoder?.stop()
            try? active.mediaProducer?.finish()
            self.activeAudioTracks.removeValue(forKey: trackHandle.name)
            trackHandle.transition(to: .stopped)
            self.eventsContinuation.yield(.trackStopped(trackHandle.name))
            self.checkAllTracksStopped()
        }

        activeAudioTracks[desc.track.name] = active
    }

    // MARK: - Private: Object Track Wiring

    private func startObjectTrack(_ desc: DataTrackDescriptor) throws {
        let active = DataTrack()
        let producer = try broadcast.publishTrack(name: desc.track.name)
        active.producer = producer
        active.emitter = desc.emitter
        desc.emitter.attach(producer)

        let trackHandle = desc.track
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.emitter?.detach()
            self.activeDataTracks.removeValue(forKey: trackHandle.name)
            trackHandle.transition(to: .stopped)
            self.eventsContinuation.yield(.trackStopped(trackHandle.name))
            self.checkAllTracksStopped()
        }

        trackHandle.transition(to: .active)
        eventsContinuation.yield(.trackStarted(trackHandle.name))
        activeDataTracks[desc.track.name] = active
    }

    // MARK: - Private: Lifecycle

    private func checkAllTracksStopped() {
        if activeVideoTracks.isEmpty && activeAudioTracks.isEmpty && activeDataTracks.isEmpty
            && currentState == .publishing
        {
            transition(to: .stopped)
            stateContinuation.finish()
            eventsContinuation.finish()
        }
    }
}
