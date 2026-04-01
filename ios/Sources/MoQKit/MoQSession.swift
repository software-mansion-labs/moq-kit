import Foundation
import MoQKitFFI

// MARK: - MoQSessionError (codec/format related)

/// Errors thrown by ``MoQSession`` and ``MoQPlayer``.
public enum MoQSessionError: Error, Sendable {
    /// The track uses a codec that MoQKit does not support.
    case unsupportedCodec(String)
    /// A video codec requires an out-of-band parameter set (SPS/PPS/VPS) but none was provided.
    case missingCodecDescription
    /// `CMFormatDescription` creation failed with the given OS status code.
    case formatDescriptionFailed(OSStatus)
    /// `CMSampleBuffer` creation failed with the given OS status code.
    case sampleBufferFailed(OSStatus)
    /// ``MoQSession/connect()`` was called on a session that is already connecting or connected.
    case alreadyConnected
    /// ``MoQSession/connect()`` was called after ``MoQSession/close()`` — create a new session instead.
    case alreadyClosed
    /// No tracks were found in the broadcast catalog.
    case noTracksAvailable
    /// No broadcast was found at the given path.
    case noBroadcastAvailable
    /// ``MoQPlayer`` was initialised with an empty track list.
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

/// The lifecycle state of a ``MoQSession``.
public enum MoQSessionState: Sendable, Equatable {
    /// Initial state. ``MoQSession/connect()`` has not been called yet.
    case idle
    /// QUIC handshake is in progress.
    case connecting
    /// Transport is ready. The session is watching for broadcast announcements and
    /// will emit events on ``MoQSession/broadcasts``.
    case connected
    /// An irrecoverable error occurred. The associated string contains a human-readable
    /// description. The session cannot be reused — create a new one.
    case error(String)
    /// The session was closed via ``MoQSession/close()``. No further events will be emitted.
    case closed
}

// MARK: - MoQSession

/// Manages a single MoQ relay connection and surfaces available broadcasts.
///
/// `MoQSession` is the primary entry point for the MoQKit SDK. Create one with a relay
/// URL, call ``connect()``, and observe ``broadcasts`` to discover live streams:
///
/// ```swift
/// let session = MoQSession(url: "https://relay.example.com/moq")
/// try await session.connect()
///
/// for await event in session.broadcasts {
///     if case .available(let info) = event {
///         let player = try MoQPlayer(tracks: info.videoTracks + info.audioTracks)
///         try await player.play()
///     }
/// }
/// ```
///
/// The class is `@MainActor` — all calls must be made from the main actor.
@MainActor
public final class MoQSession {
    /// Emits the current ``MoQSessionState`` and every subsequent state change.
    ///
    /// The stream always yields `.idle` as its first element. It completes when the
    /// session reaches `.closed`.
    public let state: AsyncStream<MoQSessionState>

    /// Emits ``MoQBroadcastEvent`` values as broadcasts appear and disappear on the relay.
    ///
    /// Each `.available` event carries a ``MoQBroadcastInfo`` describing the catalog of
    /// tracks for that broadcast. A subsequent `.unavailable` event with the same path
    /// signals that the broadcast has ended.
    public let broadcasts: AsyncStream<MoQBroadcastEvent>

    private let url: String
    private let prefix: String

    private let stateContinuation: AsyncStream<MoQSessionState>.Continuation
    private let broadcastsContinuation: AsyncStream<MoQBroadcastEvent>.Continuation
    private var currentState: MoQSessionState = .idle

    // Pipeline objects
    private var client: MoqClient?
    private var origin: MoqOriginProducer?
    private var session: MoqSession?
    private var consumer: MoqOriginConsumer?
    private var announced: MoqAnnounced?

    // Per-path broadcast state
    private var activeBroadcasts: [String: Task<Void, Never>] = [:]
    private var catalogConsumers: [String: MoqCatalogConsumer] = [:]

    // Background tasks
    private var sessionMonitorTask: Task<Void, Never>?
    private var announcedTask: Task<Void, Never>?

    /// Creates a new session.
    ///
    /// - Parameters:
    ///   - url: The WebTransport URL of the MoQ relay (e.g. `"https://relay.example.com/moq"`).
    ///   - prefix: Optional broadcast path prefix. Only broadcasts whose path starts with this
    ///     string will be surfaced on ``broadcasts``. Pass `""` (the default) to receive all
    ///     broadcasts on the relay.
    public init(url: String, prefix: String = "") {
        self.url = url
        self.prefix = prefix

        var stateCont: AsyncStream<MoQSessionState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var broadcastsCont: AsyncStream<MoQBroadcastEvent>.Continuation!
        self.broadcasts = AsyncStream { broadcastsCont = $0 }
        self.broadcastsContinuation = broadcastsCont

        stateContinuation.yield(.idle)
    }

    /// Establishes the QUIC connection to the relay and starts watching for broadcast announcements.
    ///
    /// Transitions the session through `.connecting` → `.connected`. Once connected, incoming
    /// broadcasts are emitted on ``broadcasts``.
    ///
    /// - Throws: ``MoQSessionError/alreadyConnected`` if called while connecting or connected.
    /// - Throws: ``MoQSessionError/alreadyClosed`` if the session has already been closed.
    /// - Throws: ``MoQSessionError/connectionFailed(_:)`` if the transport handshake fails.
    public func connect() async throws {
        guard currentState == .idle else {
            if currentState == .closed { throw MoQSessionError.alreadyClosed }
            throw MoQSessionError.alreadyConnected
        }

        MoQLogger.session.debug("Connecting to \(self.url)")
        transition(to: .connecting)

        do {
            // 1. Create origin and client
            let origin = MoqOriginProducer()
            self.origin = origin

            let client = MoqClient()
            client.setConsume(origin: origin)
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
                    MoQLogger.session.warning("Session ended with error: \(error)")
                    self.transition(to: .error("Session ended: \(error)"))
                    await self.close()
                    return
                }
                guard let self else { return }
                if self.currentState == .connected {
                    MoQLogger.session.warning("Session ended unexpectedly")
                    self.transition(to: .error("Session ended unexpectedly"))
                    await self.close()
                }
            }

            // 5. Watch announcements
            let consumer = origin.consume()
            self.consumer = consumer
            let announced = try consumer.announced(prefix: "")
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

                        MoQLogger.session.debug("Broadcast active: \(path)")
                        do {
                            try self.handleActiveBroadcast(
                                path: path, broadcast: broadcast)
                        } catch {
                            MoQLogger.session.error(
                                "handleActiveBroadcast failed for \(path): \(error)")
                        }
                    } catch MoqError.Cancelled {
                        break
                    } catch {
                        MoQLogger.session.error("announced() failed: \(error)")
                        break
                    }
                }
            }

        } catch let error as MoqError {
            MoQLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw MoQSessionError.connectionFailed(error.localizedDescription)
        } catch let error as MoQSessionError {
            MoQLogger.session.error("Connection failed: \(error)")
            transition(to: .error("\(error)"))
            await tearDown()
            throw error
        } catch {
            MoQLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw error
        }
    }

    /// Closes the relay connection and releases all resources.
    ///
    /// Transitions the session to `.closed` and completes both ``state`` and ``broadcasts``
    /// streams. Safe to call multiple times — subsequent calls are no-ops.
    public func close() async {
        guard currentState != .closed else { return }
        MoQLogger.session.debug("Closing session")
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
        announced?.cancel()
        client?.cancel()
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    // MARK: - Private

    private func handleActiveBroadcast(path: String, broadcast: MoqBroadcastConsumer) throws {
        MoQLogger.session.debug("Subscribing to catalog for \(path)")
        let catalogConsumer = try broadcast.subscribeCatalog()
        self.catalogConsumers[path] = catalogConsumer

        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let catalog = try await catalogConsumer.next() else {
                        MoQLogger.session.debug("Catalog stream ended for \(path)")
                        self.broadcastsContinuation.yield(.unavailable(path: path))
                        self.catalogConsumers.removeValue(forKey: path)
                        break
                    }
                    guard !Task.isCancelled else { break }
                    MoQLogger.session.debug("Catalog updated for \(path)")
                    let info = self.buildBroadcastInfo(
                        from: catalog, broadcast: broadcast, path: path)
                    self.broadcastsContinuation.yield(.available(info))
                } catch MoqError.Cancelled {
                    self.catalogConsumers.removeValue(forKey: path)
                    break
                } catch {
                    MoQLogger.session.error("subscribeCatalog() failed (\(path)): \(error)")
                    self.catalogConsumers.removeValue(forKey: path)
                    break
                }
            }
        }
        self.activeBroadcasts[path] = task
    }

    private func transition(to newState: MoQSessionState) {
        MoQLogger.session.debug(
            "State: \(String(describing: self.currentState)) → \(String(describing: newState))")
        currentState = newState
        stateContinuation.yield(newState)
    }

    /// Build a `MoQBroadcastInfo` by enumerating all video and audio renditions in the catalog.
    private func buildBroadcastInfo(
        from catalog: MoqCatalog, broadcast: MoqBroadcastConsumer, path: String
    ) -> MoQBroadcastInfo {
        let videoTracks = catalog.video.map { (name, rendition) in
            MoQVideoTrackInfo(name: name, config: rendition, broadcast: broadcast)
        }
        let audioTracks = catalog.audio.map { (name, rendition) in
            MoQAudioTrackInfo(name: name, config: rendition, broadcast: broadcast)
        }

        return MoQBroadcastInfo(path: path, videoTracks: videoTracks, audioTracks: audioTracks)
    }

    private func tearDown() async {
        MoQLogger.session.debug("Tearing down session")

        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        announcedTask?.cancel()
        announcedTask = nil

        for (_, task) in activeBroadcasts { task.cancel() }
        activeBroadcasts.removeAll()

        for (_, consumer) in catalogConsumers { consumer.cancel() }
        catalogConsumers.removeAll()

        announced?.cancel()
        announced = nil

        session?.cancel(code: 0)
        session = nil

        client?.cancel()
        client = nil

        consumer = nil
        origin = nil
    }
}
