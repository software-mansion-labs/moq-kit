import AVFoundation
import CoreMedia
import Moq

// MARK: - Publisher State & Events

/// The lifecycle state of a ``Publisher``.
public enum PublisherState: Sendable, Equatable {
    /// Created, no tracks publishing yet.
    case idle
    /// Broadcast is open; capture tracks may be running or waiting for their sources.
    case publishing
    /// Broadcast explicitly ended and finalized.
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
public enum PublishedTrackState: Sendable, Equatable {
    /// Added, or waiting for a stopped capture source to restart.
    case idle
    /// Publication is disabled and owns no encoder or media producer.
    case disabled
    /// Activation or output failed; setEnabled(true) retries.
    case failed(String)
    /// Encoder started, waiting for first encoded frame.
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
public class PublishedTrack: @unchecked Sendable {
    public let name: String
    public let codecInfo: TrackCodecInfo
    public let state: AsyncStream<PublishedTrackState>
    internal let stateContinuation: AsyncStream<PublishedTrackState>.Continuation
    internal var currentState: PublishedTrackState = .idle
    internal var stopAction: (() -> Void)?
    internal var releaseAction: (() -> Void)?

    init(name: String, codecInfo: TrackCodecInfo) {
        self.name = name
        self.codecInfo = codecInfo
        var continuation: AsyncStream<PublishedTrackState>.Continuation!
        state = AsyncStream { continuation = $0 }
        stateContinuation = continuation
        continuation.yield(.idle)
    }

    /// Permanently detach this track. The broadcast and capture remain independent.
    public func stop() async {
        await PublishControl.finish { self.stopOwned() }
    }

    internal func stopOwned() {
        guard currentState != .stopped else { return }
        stopAction?()
        stopAction = nil
        releaseAction?()
        releaseAction = nil
        transition(to: .stopped)
    }

    internal func transition(to state: PublishedTrackState) {
        guard currentState != .stopped, currentState != state else { return }
        currentState = state
        stateContinuation.yield(state)
        if state == .stopped { stateContinuation.finish() }
    }

    deinit { stateContinuation.finish() }
}

/// Reusable publication attachment shared by audio and video. Capture is started explicitly.
public final class PublishedMediaTrack: PublishedTrack, @unchecked Sendable {
    internal var enabledValue = true
    internal var binding: CaptureTrackBinding?
    internal var outputID: UUID?

    /// Requested publication setting, independent of capture availability.
    public var isEnabled: Bool { PublishControl.sync { enabledValue } }

    /// Await encoder setup or teardown. Enabling a stopped source only records intent.
    public func setEnabled(_ enabled: Bool) async throws {
        try Task.checkCancellation()
        try await PublishControl.run {
            guard self.currentState != .stopped else { throw SessionError.alreadyClosed }
            self.enabledValue = enabled
            if let binding = self.binding { try binding.setEnabled(enabled) }
            else { self.transition(to: enabled ? .idle : .disabled) }
        }
    }
}

// MARK: - Track Descriptors (internal)

/// Describes a video track to be started when `start()` is called.
private struct VideoTrackDescriptor {
    let track: PublishedMediaTrack
    let source: any FrameSource
    let config: VideoEncoderConfig
}

/// Describes an audio track to be started when `start()` is called.
private struct AudioTrackDescriptor {
    let track: PublishedMediaTrack
    let source: any FrameSource
    let config: AudioEncoderConfig
}

/// Describes an object track to be started when `start()` is called.
private struct DataTrackDescriptor {
    let track: PublishedTrack
    let emitter: DataTrackEmitter
}

// MARK: - Active Track State (internal)

/// Holds the runtime objects for an active object track.
private final class DataTrack {
    var emitter: DataTrackEmitter?
    var producer: Moq.TrackProducer?
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
/// let video = try publisher.addVideoTrack(name: "video", source: camera)
/// try session.publish(path: "live/stream", publisher: publisher)
/// try await publisher.start()
/// ```
///
/// A `Publisher` is single-use. After ``stop()`` completes, create a new instance for the
/// next broadcast.
public final class Publisher: @unchecked Sendable {
    /// Emits ``PublisherState`` values for the lifetime of the publisher.
    public let state: AsyncStream<PublisherState>
    /// Emits ``PublisherEvent`` values as tracks start, stop, or fail.
    public let events: AsyncStream<PublisherEvent>

    /// The underlying Moq broadcast producer, created by ``Session/publish(path:publisher:)``
    /// at the broadcast path. Tracks cannot start before it is attached.
    internal private(set) var broadcast: Moq.BroadcastProducer?

    internal let clock = PublisherClock()

    internal func attachBroadcast(_ broadcast: Moq.BroadcastProducer) throws {
        try PublishControl.sync {
            guard currentState == .idle, self.broadcast == nil else {
                throw SessionError.invalidConfiguration("Publisher is already registered with a session")
            }
            self.broadcast = broadcast
        }
    }

    private let stateContinuation: AsyncStream<PublisherState>.Continuation
    private let eventsContinuation: AsyncStream<PublisherEvent>.Continuation
    private var currentState: PublisherState = .idle

    // Track descriptors (added before start)
    private var videoDescriptors: [VideoTrackDescriptor] = []
    private var audioDescriptors: [AudioTrackDescriptor] = []
    private var dataDescriptors: [DataTrackDescriptor] = []

    // Active runtime state
    private var activeDataTracks: [String: DataTrack] = [:]

    /// Create a publisher. Does not start publishing until ``start()`` is called.
    public init() throws {
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
    ///   - name: Local SDK label used by ``PublishedTrack`` and ``PublisherEvent``.
    ///     Media catalog track names are generated by the underlying muxer; discover them
    ///     from ``Catalog/videoTracks``.
    ///   - source: A frame source that produces video sample buffers.
    ///   - config: Video encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addVideoTrack(
        name: String = "video",
        source: any FrameSource,
        config: VideoEncoderConfig = VideoEncoderConfig(),
        enabled: Bool = true
    ) throws -> PublishedMediaTrack {
        try PublishControl.sync {
            try validateRegistration(name)
            let lifecycle = captureLifecycle(for: source)
            let reservation = UUID()
            try lifecycle?.reserve(reservation)
            let track = PublishedMediaTrack(name: name, codecInfo: .video(codec: config.codec, width: config.width, height: config.height, frameRate: config.maxFrameRate))
            track.enabledValue = enabled
            if !enabled { track.transition(to: .disabled) }
            track.releaseAction = { lifecycle?.release(reservation) }
            let events = eventsContinuation
            track.stopAction = { [weak track] in
                track?.outputID = nil
                track?.binding?.stop()
                track?.binding = nil
                events.yield(.trackStopped(name))
            }
            videoDescriptors.append(VideoTrackDescriptor(track: track, source: source, config: config))
            return track
        }
    }

    /// Adds an audio track backed by a frame source.
    ///
    /// Starting the capture source itself remains the app's responsibility.
    /// - Parameters:
    ///   - name: Local SDK label used by ``PublishedTrack`` and ``PublisherEvent``.
    ///     Media catalog track names are generated by the underlying muxer; discover them
    ///     from ``Catalog/audioTracks``.
    ///   - source: A frame source that produces audio sample buffers.
    ///   - config: Audio encoder configuration.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addAudioTrack(
        name: String = "audio",
        source: any FrameSource,
        config: AudioEncoderConfig = AudioEncoderConfig(),
        enabled: Bool = true
    ) throws -> PublishedMediaTrack {
        try PublishControl.sync {
            try validateRegistration(name)
            let lifecycle = captureLifecycle(for: source)
            let reservation = UUID()
            try lifecycle?.reserve(reservation)
            let track = PublishedMediaTrack(name: name, codecInfo: .audio(codec: config.codec, sampleRate: config.sampleRate))
            track.enabledValue = enabled
            if !enabled { track.transition(to: .disabled) }
            track.releaseAction = { lifecycle?.release(reservation) }
            let events = eventsContinuation
            track.stopAction = { [weak track] in
                track?.outputID = nil
                track?.binding?.stop()
                track?.binding = nil
                events.yield(.trackStopped(name))
            }
            audioDescriptors.append(AudioTrackDescriptor(track: track, source: source, config: config))
            return track
        }
    }

    /// Adds a data track for app-defined binary payloads.
    ///
    /// - Parameters:
    ///   - name: Track name in the broadcast catalog. Defaults to `"data"`.
    ///   - source: Emitter the app uses to push objects after ``start()`` succeeds.
    /// - Returns: A handle to control the track independently.
    @discardableResult
    public func addDataTrack(name: String = "data", source: DataTrackEmitter) throws -> PublishedTrack {
        try PublishControl.sync {
            try validateRegistration(name)
            let track = PublishedTrack(name: name, codecInfo: .data)
            dataDescriptors.append(DataTrackDescriptor(track: track, emitter: source))
            return track
        }
    }

    private func validateRegistration(_ name: String) throws {
        guard currentState == .idle else {
            throw SessionError.invalidConfiguration("Add tracks before Publisher.start()")
        }
        guard !(videoDescriptors.map { $0.track.name } + audioDescriptors.map { $0.track.name }
                + dataDescriptors.map { $0.track.name }).contains(name) else {
            throw SessionError.invalidConfiguration("Track '\(name)' already added")
        }
    }

    /// Starts publishing all registered tracks.
    ///
    /// Call ``Session/publish(path:publisher:)`` before this method. `start()` does not
    /// start `CameraCapture`, `MicrophoneCapture`, or any custom source for you; it only
    /// binds those sources to encoders and the relay-facing producers.
    public func start() async throws {
        try Task.checkCancellation()
        try await PublishControl.run {
            guard self.currentState == .idle else {
                throw SessionError.invalidConfiguration("Publisher already started")
            }
            guard let broadcast = self.broadcast else {
                throw SessionError.invalidConfiguration("Register Publisher with Session.publish() before start()")
            }
            do {
                for desc in self.videoDescriptors where desc.track.currentState != .stopped {
                    try self.startVideoTrack(desc, broadcast: broadcast)
                }
                for desc in self.audioDescriptors where desc.track.currentState != .stopped {
                    try self.startAudioTrack(desc, broadcast: broadcast)
                }
                for desc in self.dataDescriptors where desc.track.currentState != .stopped {
                    try self.startObjectTrack(desc, broadcast: broadcast)
                }
                self.transition(to: .publishing)
            } catch {
                self.stopOwned(finalState: .error(error.localizedDescription))
                throw error
            }
        }
    }

    /// End the broadcast and await publication teardown. Capture and preview continue.
    public func stop() async {
        await PublishControl.finish { self.stopOwned() }
    }

    internal func stopOwned(finalState: PublisherState = .stopped) {
        guard currentState == .publishing || currentState == .idle else { return }
        for desc in videoDescriptors { desc.track.stopOwned() }
        for desc in audioDescriptors { desc.track.stopOwned() }
        for desc in dataDescriptors { desc.track.stopOwned() }
        activeDataTracks.removeAll()
        try? broadcast?.finish()
        broadcast = nil
        clock.reset()
        transition(to: finalState)
        stateContinuation.finish()
        eventsContinuation.finish()
    }

    deinit { PublishControl.sync { stopOwned() } }

    // MARK: - Private: State

    private func transition(to newState: PublisherState) {
        KitLogger.publish.debug(
            "Publisher state: \(String(describing: self.currentState)) → \(String(describing: newState))"
        )
        currentState = newState
        stateContinuation.yield(newState)
    }

    // MARK: - Private: Video Track Wiring

    private func captureLifecycle(for source: any FrameSource) -> CaptureLifecycle? {
        if let camera = source as? CameraCapture { return camera.captureLifecycle }
        if let microphone = source as? MicrophoneCapture { return microphone.captureLifecycle }
        return nil
    }

    private func mediaOutput(
        for track: PublishedMediaTrack, broadcast: Moq.BroadcastProducer, format: String
    ) -> MediaTrackOutput {
        let events = eventsContinuation
        let id = UUID()
        track.outputID = id
        return MediaTrackOutput(
            broadcast: broadcast, format: format,
            onActive: { [weak track] in
                PublishControl.queue.async {
                    guard let track, track.outputID == id, track.currentState != .stopped else { return }
                    track.transition(to: .active)
                    events.yield(.trackStarted(track.name))
                }
            },
            onError: { [weak track] error in
                PublishControl.queue.async {
                    guard let track, track.outputID == id else { return }
                    track.binding?.fail(error)
                }
            }
        )
    }

    private func startVideoTrack(_ desc: VideoTrackDescriptor, broadcast: Moq.BroadcastProducer) throws {
        let track = desc.track
        let clock = self.clock
        let events = eventsContinuation
        let binding = CaptureTrackBinding(
            enabled: track.enabledValue,
            start: { [weak self] in
                guard let self else { throw SessionError.alreadyClosed }
                if let reason = desc.config.unsupportedReason {
                    throw SessionError.unsupportedCodec(reason)
                }
                let encoder = VideoEncoder(config: desc.config)
                let gate = CaptureFrameGate()
                let output = self.mediaOutput(for: track, broadcast: broadcast, format: desc.config.format)
                track.transition(to: .starting)
                do {
                    try encoder.start(onError: output.fail) { frame in
                        output.write(frame.data, initData: frame.initData,
                                     timestampUs: clock.timestampUs(from: frame.presentationTime))
                    }
                } catch {
                    output.finish()
                    encoder.stop()
                    throw error
                }
                desc.source.onFrame = { sample in
                    gate.send { encoder.encode(sample) }
                }
                return {
                    track.outputID = nil
                    output.finish()
                    desc.source.onFrame = nil
                    gate.close { encoder.stop() }
                }
            },
            onState: { track.transition(to: $0) },
            onError: { error in events.yield(.error(track.name, error.localizedDescription)) },
            onClosed: { track.stopOwned() }
        )
        track.binding = binding
        try binding.attach(to: captureLifecycle(for: desc.source))
    }

    private func startAudioTrack(_ desc: AudioTrackDescriptor, broadcast: Moq.BroadcastProducer) throws {
        let track = desc.track
        let clock = self.clock
        let events = eventsContinuation
        let binding = CaptureTrackBinding(
            enabled: track.enabledValue,
            start: { [weak self] in
                guard let self else { throw SessionError.alreadyClosed }
                if let reason = desc.config.unsupportedReason {
                    throw SessionError.unsupportedCodec(reason)
                }
                let encoder = AudioEncoder(config: desc.config)
                let gate = CaptureFrameGate()
                let output = self.mediaOutput(for: track, broadcast: broadcast, format: desc.config.format)
                track.transition(to: .starting)
                do {
                    try encoder.start(onError: output.fail) { frame in
                        output.write(frame.data, initData: frame.initData,
                                     timestampUs: clock.timestampUs(from: frame.presentationTime))
                    }
                } catch {
                    output.finish()
                    encoder.stop()
                    throw error
                }
                desc.source.onFrame = { sample in
                    gate.send { encoder.encode(sample) }
                }
                return {
                    track.outputID = nil
                    output.finish()
                    desc.source.onFrame = nil
                    gate.close { encoder.stop() }
                }
            },
            onState: { track.transition(to: $0) },
            onError: { error in events.yield(.error(track.name, error.localizedDescription)) },
            onClosed: { track.stopOwned() }
        )
        track.binding = binding
        try binding.attach(to: captureLifecycle(for: desc.source))
    }

    // MARK: - Private: Object Track Wiring

    private func startObjectTrack(_ desc: DataTrackDescriptor, broadcast: Moq.BroadcastProducer) throws {
        let active = DataTrack()
        let producer = try broadcast.publishTrack(name: desc.track.name, info: nil)
        active.producer = producer
        active.emitter = desc.emitter
        desc.emitter.attach(producer, clock: clock)

        let trackHandle = desc.track
        trackHandle.stopAction = { [weak self, weak active] in
            guard let self, let active else { return }
            active.emitter?.detach()
            try? active.producer?.finish()
            self.activeDataTracks.removeValue(forKey: trackHandle.name)
            trackHandle.transition(to: .stopped)
            self.eventsContinuation.yield(.trackStopped(trackHandle.name))
        }

        trackHandle.transition(to: .active)
        eventsContinuation.yield(.trackStarted(trackHandle.name))
        activeDataTracks[desc.track.name] = active
    }

}
