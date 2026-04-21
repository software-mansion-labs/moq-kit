import Foundation
import MoQKitFFI

// MARK: - SessionError (codec/format related)

/// Errors thrown by ``Session`` and ``Player``.
public enum SessionError: Error, Sendable {
    /// The track uses a codec that MoQKit does not support.
    case unsupportedCodec(String)
    /// A video codec requires an out-of-band parameter set (SPS/PPS/VPS) but none was provided.
    case missingCodecDescription
    /// `CMFormatDescription` creation failed with the given OS status code.
    case formatDescriptionFailed(OSStatus)
    /// `CMSampleBuffer` creation failed with the given OS status code.
    case sampleBufferFailed(OSStatus)
    /// ``Session/connect()`` was called on a session that is already connecting or connected.
    case alreadyConnected
    /// ``Session/connect()`` was called after ``Session/close()`` — create a new session instead.
    case alreadyClosed
    /// No tracks were found in the broadcast catalog.
    case noTracksAvailable
    /// No broadcast was found at the given path.
    case noBroadcastAvailable
    /// ``Player`` was initialised with an empty track list.
    case noTracksSelected
    /// A configuration invariant was violated (details in the associated string).
    case invalidConfiguration(String)
    /// The audio decoder failed to initialise or decode a frame.
    case audioDecoderFailed(String)
    /// The underlying QUIC/WebTransport connection failed. The associated string contains
    /// the transport-level error description.
    case connectionFailed(String)
}

// MARK: - State

/// The lifecycle state of a ``Session``.
public enum SessionState: Sendable, Equatable {
    /// Initial state. ``Session/connect()`` has not been called yet.
    case idle
    /// QUIC handshake is in progress.
    case connecting
    /// Transport is ready. The session is watching for broadcast announcements and
    /// will emit events on ``Session/broadcasts``.
    case connected
    /// An irrecoverable error occurred. The associated string contains a human-readable
    /// description. The session cannot be reused — create a new one.
    case error(String)
    /// The session was closed via ``Session/close()``. No further events will be emitted.
    case closed
}

// MARK: - Session

/// Manages a single MoQ relay connection and surfaces available broadcasts.
///
/// `Session` is the primary entry point for the MoQKit SDK. Create one with a relay
/// URL and call ``connect()``. To discover live streams, call ``subscribe(prefix:)``
/// after connecting and observe ``broadcasts``:
///
/// ```swift
/// let session = Session(url: "https://relay.example.com/moq")
/// try await session.connect()
/// try session.subscribe()
///
/// for await event in session.broadcasts {
///     if case .available(let info) = event {
///         let player = try Player(tracks: info.videoTracks + info.audioTracks)
///         try await player.play()
///     }
/// }
/// ```
///
/// To publish without consuming, simply omit the ``subscribe(prefix:)`` call:
///
/// ```swift
/// let session = Session(url: "https://relay.example.com/moq")
/// try await session.connect()
/// try session.publish(path: "live/my-stream", publisher: publisher)
/// ```
///
/// The class is `@MainActor` — all calls must be made from the main actor.
@MainActor
public final class Session {
    /// Emits the current ``SessionState`` and every subsequent state change.
    ///
    /// The stream always yields `.idle` as its first element. It completes when the
    /// session reaches `.closed`.
    public let state: AsyncStream<SessionState>

    /// Emits ``BroadcastEvent`` values as broadcasts appear and disappear on the relay.
    ///
    /// Each `.available` event carries a ``BroadcastInfo`` describing the catalog of
    /// tracks for that broadcast. A subsequent `.unavailable` event with the same path
    /// signals that the broadcast has ended.
    public let broadcasts: AsyncStream<BroadcastEvent>

    private let url: String

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private let broadcastsContinuation: AsyncStream<BroadcastEvent>.Continuation
    private var currentState: SessionState = .idle

    // Pipeline objects
    private var client: MoqClient?
    private var consumeOrigin: MoqOriginProducer?
    private var publishOrigin: MoqOriginProducer?
    private var session: MoqSession?
    private var consumer: MoqOriginConsumer?
    private var announced: MoqAnnounced?

    // Per-path broadcast state (consuming)
    private var activeBroadcasts: [String: Task<Void, Never>] = [:]
    private var catalogConsumers: [String: MoqCatalogConsumer] = [:]

    // Per-path publish state
    private var activePublishers: [String: Publisher] = [:]

    // Background tasks
    private var sessionMonitorTask: Task<Void, Never>?
    private var announcedTask: Task<Void, Never>?

    /// Creates a new session.
    ///
    /// - Parameter url: The WebTransport URL of the MoQ relay (e.g. `"https://relay.example.com/moq"`).
    public init(url: String) {
//        do {
//            try moqLogLevel(level: "TRACE")
//        } catch {}
        self.url = url

        var stateCont: AsyncStream<SessionState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var broadcastsCont: AsyncStream<BroadcastEvent>.Continuation!
        self.broadcasts = AsyncStream { broadcastsCont = $0 }
        self.broadcastsContinuation = broadcastsCont

        stateContinuation.yield(.idle)
    }

    /// Establishes the QUIC connection to the relay.
    ///
    /// Transitions the session through `.connecting` → `.connected`. To start receiving
    /// broadcast announcements, call ``subscribe(prefix:)`` after connecting.
    ///
    /// - Throws: ``SessionError/alreadyConnected`` if called while connecting or connected.
    /// - Throws: ``SessionError/alreadyClosed`` if the session has already been closed.
    /// - Throws: ``SessionError/connectionFailed(_:)`` if the transport handshake fails.
    public func connect() async throws {
        guard currentState == .idle else {
            if currentState == .closed { throw SessionError.alreadyClosed }
            throw SessionError.alreadyConnected
        }

        KitLogger.session.debug("Connecting to \(self.url)")
        transition(to: .connecting)

        do {
            // 1. Create separate origins for consuming and publishing
            let consumeOrigin = MoqOriginProducer()
            self.consumeOrigin = consumeOrigin

            let publishOrigin = MoqOriginProducer()
            self.publishOrigin = publishOrigin

            let client = MoqClient()
            client.setTlsDisableVerify(disable: true)
            client.setConsume(origin: consumeOrigin)
            client.setPublish(origin: publishOrigin)
            self.client = client

            // 2. Connect session
            let session = try await client.connect(url: url)
            self.session = session

            // 3. Connection established
            transition(to: .connected)

            // 4. Monitor session lifetime
            sessionMonitorTask = Task { [weak self] in
                do {
                    try await session.closed()
                } catch {
                    guard let self else { return }
                    KitLogger.session.warning("Session ended with error: \(error)")
                    self.transition(to: .error("Session ended: \(error)"))
                    await self.close()
                    return
                }
                guard let self else { return }
                if self.currentState == .connected {
                    KitLogger.session.warning("Session ended unexpectedly")
                    self.transition(to: .error("Session ended unexpectedly"))
                    await self.close()
                }
            }

        } catch let error as MoqError {
            KitLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw SessionError.connectionFailed(error.localizedDescription)
        } catch let error as SessionError {
            KitLogger.session.error("Connection failed: \(error)")
            transition(to: .error("\(error)"))
            await tearDown()
            throw error
        } catch {
            KitLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw error
        }
    }

    /// Starts watching for broadcast announcements on the relay.
    ///
    /// Call this after ``connect()`` to begin receiving ``BroadcastEvent`` values on
    /// ``broadcasts``. This is not needed when the session is used only for publishing.
    ///
    /// - Parameter prefix: Only broadcasts whose path starts with this string will be surfaced.
    ///   Pass `""` (the default) to receive all broadcasts.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if the session is not connected.
    public func subscribe(prefix: String = "") throws {
        guard currentState == .connected else {
            throw SessionError.invalidConfiguration(
                "Session must be connected before subscribing")
        }
        guard let consumeOrigin else {
            throw SessionError.invalidConfiguration("Consume origin not available")
        }

        KitLogger.session.debug("Subscribing to announcements with prefix: \(prefix)")

        let consumer = consumeOrigin.consume()
        self.consumer = consumer
        let announced = try consumer.announced(prefix: prefix)
        self.announced = announced

        announcedTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    guard let announcement = try await announced.next() else {
                        break
                    }
                    let path = announcement.path()
                    let broadcast = announcement.broadcast()

                    // Cancel existing broadcast task for this path
                    self.activeBroadcasts[path]?.cancel()
                    self.activeBroadcasts.removeValue(forKey: path)
                    self.catalogConsumers[path]?.cancel()
                    self.catalogConsumers.removeValue(forKey: path)

                    KitLogger.session.debug("Broadcast active: \(path)")
                    do {
                        try self.handleActiveBroadcast(
                            path: path, broadcast: broadcast)
                    } catch {
                        KitLogger.session.error(
                            "handleActiveBroadcast failed for \(path): \(error)")
                    }
                } catch MoqError.Cancelled {
                    break
                } catch {
                    KitLogger.session.error("announced() failed: \(error)")
                    break
                }
            }
        }
    }

    /// Publish a broadcast to the relay at the given path.
    ///
    /// The publisher's underlying `MoqBroadcastProducer` is registered with the relay origin.
    /// Call ``Publisher/start()`` after this to begin sending frames.
    ///
    /// - Parameters:
    ///   - path: The broadcast path on the relay (e.g. `"live/my-stream"`).
    ///   - publisher: A configured ``Publisher`` with at least one track added.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if the session is not connected.
    public func publish(path: String, publisher: Publisher) throws {
        guard currentState == .connected else {
            throw SessionError.invalidConfiguration(
                "Session must be connected before publishing")
        }
        guard let publishOrigin else {
            throw SessionError.invalidConfiguration("Publish origin not available")
        }
        KitLogger.publish.debug("Publishing broadcast at path: \(path)")
        try publishOrigin.publish(path: path, broadcast: publisher.broadcast)
        activePublishers[path] = publisher
    }

    /// Stop publishing at the given path.
    ///
    /// Calls ``Publisher/stop()`` on the publisher and removes it from the session.
    public func unpublish(path: String) {
        guard let publisher = activePublishers.removeValue(forKey: path) else { return }
        KitLogger.publish.debug("Unpublishing broadcast at path: \(path)")
        publisher.stop()
    }

    /// Closes the relay connection and releases all resources.
    ///
    /// Transitions the session to `.closed` and completes both ``state`` and ``broadcasts``
    /// streams. Safe to call multiple times — subsequent calls are no-ops.
    public func close() async {
        guard currentState != .closed else { return }
        KitLogger.session.debug("Closing session")
        await tearDown()
        transition(to: .closed)
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    deinit {
        sessionMonitorTask?.cancel()
        announcedTask?.cancel()
        for (_, task) in activeBroadcasts { task.cancel() }
        for (_, consumer) in catalogConsumers { consumer.cancel() }
        for (_, publisher) in activePublishers { Task { @MainActor in publisher.stop() } }
        announced?.cancel()
        client?.cancel()
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    // MARK: - Private

    private func handleActiveBroadcast(path: String, broadcast: MoqBroadcastConsumer) throws {
        KitLogger.session.debug("Subscribing to catalog for \(path)")
        let catalogConsumer = try broadcast.subscribeCatalog()
        self.catalogConsumers[path] = catalogConsumer

        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let catalog = try await catalogConsumer.next() else {
                        KitLogger.session.debug("Catalog stream ended for \(path)")
                        self.broadcastsContinuation.yield(.unavailable(path: path))
                        self.catalogConsumers.removeValue(forKey: path)
                        break
                    }
                    guard !Task.isCancelled else { break }
                    KitLogger.session.debug("Catalog updated for \(path)")
                    let info = self.buildBroadcastInfo(
                        from: catalog, broadcast: broadcast, path: path)
                    self.broadcastsContinuation.yield(.available(info))
                } catch MoqError.Cancelled {
                    self.catalogConsumers.removeValue(forKey: path)
                    break
                } catch {
                    KitLogger.session.error("subscribeCatalog() failed (\(path)): \(error)")
                    self.catalogConsumers.removeValue(forKey: path)
                    break
                }
            }
        }
        self.activeBroadcasts[path] = task
    }

    private func transition(to newState: SessionState) {
        KitLogger.session.debug(
            "State: \(String(describing: self.currentState)) → \(String(describing: newState))")
        currentState = newState
        stateContinuation.yield(newState)
    }

    /// Build a `BroadcastInfo` by enumerating all video and audio renditions in the catalog.
    private func buildBroadcastInfo(
        from catalog: MoqCatalog, broadcast: MoqBroadcastConsumer, path: String
    ) -> BroadcastInfo {
        let videoTracks = catalog.video.map { (name, rendition) in
            VideoTrackInfo(name: name, config: rendition, broadcast: broadcast)
        }
        let audioTracks = catalog.audio.map { (name, rendition) in
            AudioTrackInfo(name: name, config: rendition, broadcast: broadcast)
        }

        return BroadcastInfo(path: path, videoTracks: videoTracks, audioTracks: audioTracks)
    }

    private func tearDown() async {
        KitLogger.session.debug("Tearing down session")

        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        announcedTask?.cancel()
        announcedTask = nil

        for (_, task) in activeBroadcasts { task.cancel() }
        activeBroadcasts.removeAll()

        for (_, consumer) in catalogConsumers { consumer.cancel() }
        catalogConsumers.removeAll()

        for (_, publisher) in activePublishers { publisher.stop() }
        activePublishers.removeAll()

        announced?.cancel()
        announced = nil

        session?.cancel(code: 0)
        session = nil

        client?.cancel()
        client = nil

        consumer = nil
        consumeOrigin = nil
        publishOrigin = nil
    }
}
