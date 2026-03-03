import Foundation

// MARK: - MoQSessionError (codec/format related)

public enum MoQSessionError: Error, Sendable {
    case unsupportedCodec(String)
    case missingCodecDescription
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case alreadyConnected
    case alreadyClosed
    case noTracksAvailable
    case noBroadcastAvailable
    case noTracksSelected
    case connectionFailed(MoqError)
}

// MARK: - State

public enum MoQSessionState: Sendable, Equatable {
    case idle
    case connecting   // Establishing QUIC connection
    case connected    // Transport ready; watching for broadcast announcements
    case error(String)
    case closed
}

// MARK: - MoQSession

@MainActor
public final class MoQSession {
    /// Observe state changes.
    public let state: AsyncStream<MoQSessionState>

    /// Observe broadcast lifecycle events.
    public let broadcasts: AsyncStream<MoQBroadcastEvent>

    private let url: String

    private let stateContinuation: AsyncStream<MoQSessionState>.Continuation
    private let broadcastsContinuation: AsyncStream<MoQBroadcastEvent>.Continuation
    private var currentState: MoQSessionState = .idle

    // Pipeline objects
    private var origin: MoQOrigin?
    private var transport: MoQTransport?

    // Per-path broadcast state: [path: (broadcastHandle, catalogTask)]
    private var activeBroadcasts: [String: (handle: UInt32, task: Task<Void, Never>)] = [:]

    // Background tasks
    private var transportMonitorTask: Task<Void, Never>?
    private var announcedTask: Task<Void, Never>?

    public init(url: String) {
        self.url = url

        var stateCont: AsyncStream<MoQSessionState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var broadcastsCont: AsyncStream<MoQBroadcastEvent>.Continuation!
        self.broadcasts = AsyncStream { broadcastsCont = $0 }
        self.broadcastsContinuation = broadcastsCont

        stateContinuation.yield(.idle)
    }

    /// Connect to the relay and begin watching for broadcast announcements.
    public func connect() async throws {
        guard currentState == .idle else {
            if currentState == .closed { throw MoQSessionError.alreadyClosed }
            throw MoQSessionError.alreadyConnected
        }

        MoQLogger.session.debug("Connecting to \(self.url)")
        transition(to: .connecting)

        do {
            // 1. Create origin
            let origin = try MoQOrigin()
            self.origin = origin

            // 2. Connect transport with consume origin
            let transport = try await MoQTransport.connect(url: url, consumeOrigin: origin.handle)
            self.transport = transport

            // 3. Transport is ready — transition to connected
            transition(to: .connected)

            // 4. Monitor session status
            transportMonitorTask = Task { [weak self] in
                guard let self else { return }
                for await statusCode in transport.status {
                    if statusCode != 0 {
                        MoQLogger.session.warning("Session ended with code \(statusCode)")
                        self.transition(to: .error("Session ended with code \(statusCode)"))
                        await self.close()
                        return
                    }
                }
            }

            // 5. Watch announcements — manages a catalog task per active broadcast path
            announcedTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let announcements = try origin.announced()

                    for await broadcast in announcements {
                        guard !Task.isCancelled else { break }
                        let path = broadcast.path

                        // Cancel broadcast, doesn't matter if active/inactive
                        self.activeBroadcasts[path]?.task.cancel()
                        self.activeBroadcasts.removeValue(forKey: path)

                        if broadcast.active {
                            MoQLogger.session.debug("Broadcast active: \(path)")
                            do {
                                try self.handleActiveBroadcast(broadcast)
                            } catch {
                                MoQLogger.session.error("handleActiveBroadcast failed for \(path): \(error)")
                                self.transition(to: .error("\(error)"))
                                await self.close()
                                return
                            }
                        } else {
                            MoQLogger.session.debug("Broadcast unavailable: \(path)")
                            self.broadcastsContinuation.yield(.unavailable(path: path))
                        }
                    }
                } catch {
                    MoQLogger.session.error("announced() failed: \(error)")
                }
            }

        } catch let error as MoqError {
            MoQLogger.session.error("Connection failed: \(error)")
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw MoQSessionError.connectionFailed(error)
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
    

    /// Creates a player pre-configured to subscribe to the given tracks.
    /// Must be called while the broadcast at `path` is active.
    public func makePlayer(
        path: String,
        tracks: [any MoQTrackInfo],
        maxLatencyMs: UInt64 = 500
    ) throws -> MoQAVPlayer {
        guard let entry = activeBroadcasts[path] else {
            throw MoQSessionError.noBroadcastAvailable
        }
        MoQLogger.session.debug("Creating player for \(path), tracks count = \(tracks.count), maxLatencyMs = \(maxLatencyMs)")
        return try MoQAVPlayer(tracks: tracks, broadcastHandle: entry.handle, maxLatencyMs: maxLatencyMs)
    }

    /// Stop playback and release all resources.
    public func close() async {
        guard currentState != .closed else { return }
        MoQLogger.session.debug("Closing session")
        await tearDown()
        transition(to: .closed)
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    deinit {
        transportMonitorTask?.cancel()
        announcedTask?.cancel()
        for (_, entry) in activeBroadcasts { entry.task.cancel() }
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    // MARK: - Private

    private func handleActiveBroadcast(_ broadcast: AnnouncedInfo) throws {
        let path = broadcast.path

        guard let origin = self.origin else {
            return
        }

        MoQLogger.session.debug("Subscribing to catalog for \(path)")
        let handle = try origin.consume(path: path)
        let subscription = try MoQCatalogSubscription(broadcastHandle: handle)

        let task = Task { [weak self] in
            guard let self else { return }
            for await catalog in subscription.catalogs {
                guard !Task.isCancelled else { break }
                MoQLogger.session.debug("Catalog updated for \(path)")
                let info = self.buildBroadcastInfo(from: catalog, path: path)
                self.broadcastsContinuation.yield(.available(info))
            }
        }
        self.activeBroadcasts[path] = (handle: handle, task: task)
    }

    private func transition(to newState: MoQSessionState) {
        MoQLogger.session.debug("State: \(String(describing: self.currentState)) → \(String(describing: newState))")
        currentState = newState
        stateContinuation.yield(newState)
    }

    /// Build a `MoQBroadcastInfo` by enumerating all video and audio configs in the catalog.
    private func buildBroadcastInfo(from catalog: MoQCatalog, path: String) -> MoQBroadcastInfo {
        var videoTracks: [MoQVideoTrackInfo] = []
        var audioTracks: [MoQAudioTrackInfo] = []

        var i: UInt32 = 0
        while let vc = try? catalog.videoConfig(at: i) {
            videoTracks.append(MoQVideoTrackInfo(index: i, config: vc, catalog: catalog))
            i += 1
        }

        i = 0
        while let ac = try? catalog.audioConfig(at: i) {
            audioTracks.append(MoQAudioTrackInfo(index: i, config: ac, catalog: catalog))
            i += 1
        }

        return MoQBroadcastInfo(path: path, videoTracks: videoTracks, audioTracks: audioTracks)
    }

    private func tearDown() async {
        MoQLogger.session.debug("Tearing down session")
        
        transportMonitorTask?.cancel()
        transportMonitorTask = nil
        announcedTask?.cancel()
        announcedTask = nil

        for (_, entry) in activeBroadcasts { entry.task.cancel() }
        activeBroadcasts.removeAll()

        await transport?.close()
        transport = nil

        do { try origin?.close() } catch { MoQLogger.session.error("origin.close() failed: \(error)") }
        origin = nil
    }
}
