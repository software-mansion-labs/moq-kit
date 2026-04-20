import AVFoundation
import CoreMedia
import MoQKitFFI

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

// MARK: - Track Codec Info

/// Codec information associated with a published track.
public enum MoQTrackCodecInfo: Sendable {
    case video(codec: MoQVideoCodec, width: Int32, height: Int32, frameRate: Double)
    case audio(codec: MoQAudioCodec, sampleRate: Double)
    case object
}

// MARK: - MoQPublishedTrack

/// A handle for controlling an individual track's lifecycle.
public final class MoQPublishedTrack: @unchecked Sendable {
    /// The track name.
    public let name: String
    /// Codec information for the track.
    public let codecInfo: MoQTrackCodecInfo
    /// A stream of ``MoQPublishedTrackState`` transitions.
    public let state: AsyncStream<MoQPublishedTrackState>

    internal let stateContinuation: AsyncStream<MoQPublishedTrackState>.Continuation
    internal var currentState: MoQPublishedTrackState = .idle
    internal var stopAction: (() -> Void)?

    init(name: String, codecInfo: MoQTrackCodecInfo) {
        self.name = name
        self.codecInfo = codecInfo
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
    let source: any FrameSource
    let config: MoQVideoEncoderConfig
}

/// Describes an audio track to be started when `start()` is called.
private struct AudioTrackDescriptor {
    let track: MoQPublishedTrack
    let source: any FrameSource
    let config: MoQAudioEncoderConfig
}

/// Describes an object track to be started when `start()` is called.
private struct DataTrackDescriptor {
    let track: MoQPublishedTrack
    let emitter: DataTrackEmitter
}

// MARK: - Active Track State (internal)

/// Holds the runtime objects for an active video track.
private final class VideoTrack {
    var source: (any FrameSource)?
    var encoder: MoQVideoEncoder?
    var mediaProducer: MoqMediaProducer?
}

/// Holds the runtime objects for an active audio track.
private final class AudioTrack {
    var source: (any FrameSource)?
    var encoder: MoQAudioEncoder?
    var mediaProducer: MoqMediaProducer?
}

/// Holds the runtime objects for an active object track.
private final class DataTrack {
    var emitter: DataTrackEmitter?
    var producer: MoqTrackProducer?
}

// MARK: - MoQPublisher

/// Orchestrates the encode → publish pipeline for a MoQ broadcast.
///
/// Create capture sources, then hand them to the publisher via ``addVideoTrack``
/// and ``addAudioTrack``. Call ``start()`` to bind sources to encoders and begin
/// publishing.
///
/// ```swift
/// let camera = CameraCapture(position: .back, width: 1920, height: 1080)
/// try await camera.start()
///
/// let publisher = try MoQPublisher()
/// let video = publisher.addVideoTrack(name: "video", source: camera)
/// try session.publish(path: "live/stream", publisher: publisher)
/// try await publisher.start()
/// ```
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
    private var datatDescriptors: [DataTrackDescriptor] = []

    // Active runtime state
    private var activeVideoTracks: [String: VideoTrack] = [:]
    private var activeAudioTracks: [String: AudioTrack] = [:]
    private var activeDataTracks: [String: DataTrack] = [:]

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

    /// Add a video track with an external frame source.
    ///
    /// The encoder is created and bound to the source when ``start()`` is called.
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"video"`.
    ///   - source: A frame source that produces video sample buffers.
    ///   - config: Video encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addVideoTrack(
        name: String = "video",
        source: any FrameSource,
        config: MoQVideoEncoderConfig = MoQVideoEncoderConfig()
    ) -> MoQPublishedTrack {
        let track = MoQPublishedTrack(
            name: name,
            codecInfo: .video(
                codec: config.codec, width: config.width, height: config.height,
                frameRate: config.maxFrameRate))
        videoDescriptors.append(VideoTrackDescriptor(track: track, source: source, config: config))
        return track
    }

    /// Add an audio track with an external frame source.
    ///
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"audio"`.
    ///   - source: A frame source that produces audio sample buffers.
    ///   - config: Audio encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addAudioTrack(
        name: String = "audio",
        source: any FrameSource,
        config: MoQAudioEncoderConfig = MoQAudioEncoderConfig()
    ) -> MoQPublishedTrack {
        let track = MoQPublishedTrack(
            name: name,
            codecInfo: .audio(codec: config.codec, sampleRate: config.sampleRate))
        audioDescriptors.append(AudioTrackDescriptor(track: track, source: source, config: config))
        return track
    }

    /// Add an object track for publishing raw binary data directly.
    ///
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"data"`.
    ///   - source: An emitter the caller uses to push objects onto the track.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addDataTrack(
        name: String = "data",
        source: DataTrackEmitter
    ) -> MoQPublishedTrack {
        let track = MoQPublishedTrack(name: name, codecInfo: .object)
        datatDescriptors.append(DataTrackDescriptor(track: track, emitter: source))
        return track
    }

    /// Start all encoders and bind them to their frame sources.
    ///
    /// Both video and audio tracks create their `MoqMediaProducer` lazily on the
    /// first encoded frame that carries init data (parameter sets for video,
    /// codec config for audio).
    public func start() async throws {
        guard currentState == .idle else {
            throw MoQSessionError.invalidConfiguration("Publisher already started")
        }

        MoQLogger.publish.debug(
            "Starting publisher with \(self.videoDescriptors.count) video + \(self.audioDescriptors.count) audio tracks"
        )

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

    /// Stop all tracks and finalize the broadcast.
    public func stop() {
        guard currentState == .publishing || currentState == .idle else { return }
        MoQLogger.publish.debug("Stopping publisher")

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

    private func transition(to newState: MoQPublisherState) {
        MoQLogger.publish.debug(
            "Publisher state: \(String(describing: self.currentState)) → \(String(describing: newState))"
        )
        currentState = newState
        stateContinuation.yield(newState)
    }

    // MARK: - Private: Video Track Wiring

    private func startVideoTrack(_ desc: VideoTrackDescriptor) throws {
        let active = VideoTrack()
        let encoder = MoQVideoEncoder(config: desc.config)
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
        let encoder = MoQAudioEncoder(config: desc.config)
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
                try active.mediaProducer?.writeFrame(payload: frame.data, timestampUs: timestampUs)
            } catch {
                MoQLogger.publish.error("Failed to write audio frame: \(error)")
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
