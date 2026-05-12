import Foundation
import MoQKitFFI

// MARK: - SessionError (codec/format related)

/// High-level errors surfaced by relay connection, subscription, and playback setup APIs.
public enum SessionError: Error, Sendable, Equatable {
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
    /// ``Session/subscribe(prefix:)`` was called for a prefix that is already active.
    case alreadySubscribed
    /// No tracks were found in the broadcast catalog.
    case noTracksAvailable
    /// No broadcast was found at the given path.
    case noBroadcastAvailable
    /// ``Player`` was initialised with both video and audio disabled.
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
    /// Transport is ready. The session may now publish and create broadcast subscriptions.
    case connected
    /// An irrecoverable error occurred. The session cannot be reused — create a new one.
    case error(SessionError)
    /// The session was closed via ``Session/close()``. No further events will be emitted.
    case closed
}

// MARK: - Session

/// Manages one MoQ relay connection and the broadcasts attached to it.
///
/// `Session` is the main entry point for MoQKit. Create one with a relay URL, call
/// ``connect()``, then use the same session to subscribe to broadcasts, publish tracks,
/// or both. After ``close()`` finishes, create a new session instead of reusing the old
/// instance.
///
/// To discover live streams, call ``subscribe(prefix:)`` after connecting and observe the
/// returned subscription:
///
/// ```swift
/// let session = Session(url: "https://relay.example.com/moq")
/// try await session.connect()
/// let subscription = try session.subscribe()
///
/// for await broadcast in subscription.broadcasts {
///     for await catalog in broadcast.catalogs() {
///         let videoTrack = catalog.playableVideoTracks.first?.name
///         let audioTrack = catalog.playableAudioTracks.first?.name
///         guard videoTrack != nil || audioTrack != nil else { continue }
///
///         let player = try await MainActor.run {
///             try Player(
///                 catalog: catalog,
///                 videoTrackName: videoTrack,
///                 audioTrackName: audioTrack
///             )
///         }
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
/// try await publisher.start()
/// ```
public actor Session {
    /// Emits the current ``SessionState`` and every subsequent state change.
    ///
    /// The stream always yields `.idle` as its first element. It completes when the
    /// session reaches `.closed`.
    public nonisolated let state: AsyncStream<SessionState>

    private let url: String

    private let stateContinuation: AsyncStream<SessionState>.Continuation
    private var currentState: SessionState = .idle

    // Pipeline objects
    private var client: MoqClient?
    private var consumeOrigin: MoqOriginProducer?
    private var publishOrigin: MoqOriginProducer?
    private var session: MoqSession?

    // Per-path publish state
    private var activePublishers: [String: Publisher] = [:]
    private var activeSubscriptions: [String: BroadcastSubscription] = [:]

    // Background tasks
    private var sessionMonitorTask: Task<Void, Never>?

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

        stateContinuation.yield(.idle)
    }

    /// Establishes the QUIC connection to the relay.
///
    /// Transitions the session through `.connecting` to `.connected`. After this succeeds,
    /// you can start watching broadcasts with ``subscribe(prefix:)`` and register
    /// publishers with ``publish(path:publisher:)``.
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
                    await self.handleSessionEnded(error: error)
                    return
                }
                guard let self else { return }
                await self.handleSessionEnded(error: nil)
            }

        } catch let error as MoqError {
            let sessionError = SessionError.connectionFailed(error.moqKitMessage)
            KitLogger.session.error("Connection failed: \(sessionError)")
            transition(to: .error(sessionError))
            tearDown()
            throw sessionError
        } catch let error as SessionError {
            KitLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error))
            tearDown()
            throw error
        } catch {
            let sessionError = SessionError.connectionFailed(error.localizedDescription)
            KitLogger.session.error("Connection failed: \(sessionError)")
            transition(to: .error(sessionError))
            tearDown()
            throw error
        }
    }

    /// Starts watching for broadcast announcements on the relay.
///
    /// Call this after ``connect()`` to receive broadcasts whose path starts with `prefix`.
    /// Keep the returned subscription alive for as long as you want updates, then call
    /// ``BroadcastSubscription/cancel()`` when that part of your app is done.
    ///
    /// - Parameter prefix: Only broadcasts whose path starts with this string will be surfaced.
    ///   Pass `""` (the default) to receive all broadcasts.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if the session is not connected.
    /// - Throws: ``SessionError/alreadySubscribed`` if the exact prefix is already active.
    public func subscribe(prefix: String = "") throws -> BroadcastSubscription {
        guard currentState == .connected else {
            throw SessionError.invalidConfiguration(
                "Session must be connected before subscribing")
        }
        guard let consumeOrigin else {
            throw SessionError.invalidConfiguration("Consume origin not available")
        }
        if let existingSubscription = activeSubscriptions[prefix] {
            if existingSubscription.isFinished {
                activeSubscriptions.removeValue(forKey: prefix)
            } else {
                throw SessionError.alreadySubscribed
            }
        }

        KitLogger.session.debug("Subscribing to announcements with prefix: \(prefix)")

        let consumer = consumeOrigin.consume()
        let announced = try consumer.announced(prefix: prefix)
        let subscription = BroadcastSubscription(
            prefix: prefix,
            session: self,
            announced: announced
        )
        activeSubscriptions[prefix] = subscription
        return subscription
    }

    /// Registers a broadcast publisher at the given relay path.
///
    /// This makes the publisher available on the relay, but it does not start your capture
    /// sources or encoders. Call ``Publisher/start()`` after this to begin sending frames.
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

    /// Stops publishing at the given path.
///
    /// If a publisher is registered for that path, this calls ``Publisher/stop()`` and
    /// removes it from the session. Other subscriptions and publish paths continue running.
    public func unpublish(path: String) {
        guard let publisher = activePublishers.removeValue(forKey: path) else { return }
        KitLogger.publish.debug("Unpublishing broadcast at path: \(path)")
        publisher.stop()
    }

    /// Closes the relay connection and releases all resources.
    ///
    /// Transitions the session to `.closed` and completes ``state``.
    /// Safe to call multiple times — subsequent calls are no-ops.
    public func close() async {
        guard currentState != .closed else { return }
        KitLogger.session.debug("Closing session")
        tearDown()
        transition(to: .closed)
        stateContinuation.finish()
    }

    deinit {
        sessionMonitorTask?.cancel()

        let subscriptions = Array(activeSubscriptions.values)
        activeSubscriptions.removeAll()
        for subscription in subscriptions {
            subscription.cancel()
        }

        for (_, publisher) in activePublishers {
            publisher.stop()
        }
        activePublishers.removeAll()

        session?.cancel(code: 0)
        client?.cancel()
        stateContinuation.finish()
    }

    // MARK: - Private

    private func transition(to newState: SessionState) {
        KitLogger.session.debug(
            "State: \(String(describing: self.currentState)) → \(String(describing: newState))")
        currentState = newState
        stateContinuation.yield(newState)
    }

    func removeSubscription(prefix: String, matching subscription: BroadcastSubscription) {
        guard activeSubscriptions[prefix] === subscription else { return }
        activeSubscriptions.removeValue(forKey: prefix)
    }

    private func handleSessionEnded(error: Error?) async {
        if let error {
            KitLogger.session.warning("Session ended with error: \(error)")
            transition(to: .error(.connectionFailed("Session ended: \(error.localizedDescription)")))
            await close()
            return
        }

        if currentState == .connected {
            KitLogger.session.warning("Session ended unexpectedly")
            transition(to: .error(.connectionFailed("Session ended unexpectedly")))
            await close()
        }
    }

    private func tearDown() {
        KitLogger.session.debug("Tearing down session")

        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil

        let subscriptions = Array(activeSubscriptions.values)
        activeSubscriptions.removeAll()
        for subscription in subscriptions {
            subscription.cancel()
        }

        for (_, publisher) in activePublishers { publisher.stop() }
        activePublishers.removeAll()

        session?.cancel(code: 0)
        session = nil

        client?.cancel()
        client = nil

        consumeOrigin = nil
        publishOrigin = nil
    }
}
