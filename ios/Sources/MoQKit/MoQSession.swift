import AVFoundation
import CoreMedia

// MARK: - State

public enum MoQSessionState: Sendable, Equatable {
    case idle
    case connecting   // Establishing QUIC connection
    case connected    // Transport ready; watching for broadcast announcements
    case playing      // At least one track is rendering frames
    case error(String)
    case closed
}

// MARK: - Broadcast Info

public struct MoQBroadcastTrack<T>: Sendable {
    public let index: UInt32
    public let config: T
}

/// Describes the tracks available in the current live broadcast.
public struct MoQBroadcastInfo: Sendable {
    public let videoTracks: [MoQBroadcastTrack<VideoConfig>]
    public let audioTracks: [MoQBroadcastTrack<AudioConfig>]
}

/// Lifecycle events emitted on the broadcasts stream.
public enum MoQBroadcastEvent: Sendable {
    case available(MoQBroadcastInfo)
    case unavailable
}

// MARK: - Configuration

public struct MoQSessionConfiguration: Sendable {
    public var maxLatencyMs: UInt64

    public init(maxLatencyMs: UInt64 = 500) {
        self.maxLatencyMs = maxLatencyMs
    }
}

// MARK: - MoQSession

@MainActor
public final class MoQSession {
    /// Add this layer to your view hierarchy for video display.
    public let videoLayer: AVSampleBufferDisplayLayer

    /// Observe state changes.
    public let state: AsyncStream<MoQSessionState>

    /// Observe broadcast lifecycle events.
    public let broadcasts: AsyncStream<MoQBroadcastEvent>

    private let url: String
    private let path: String
    private let configuration: MoQSessionConfiguration

    private let stateContinuation: AsyncStream<MoQSessionState>.Continuation
    private let broadcastsContinuation: AsyncStream<MoQBroadcastEvent>.Continuation
    private var currentState: MoQSessionState = .idle

    // Pipeline objects
    private var origin: MoQOrigin?
    private var transport: MoQTransport?
    private var videoTrack: MoQVideoTrack?
    private var audioTrack: MoQAudioTrack?

    // Broadcast state
    private var currentBroadcastHandle: UInt32?
    private var currentCatalog: MoQCatalog?
    private var catalogSubscription: MoQCatalogSubscription?
    private var catalogTask: Task<Void, Never>?

    // AVFoundation
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    // Background tasks
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var transportMonitorTask: Task<Void, Never>?
    private var announcedTask: Task<Void, Never>?

    public init(url: String, path: String, configuration: MoQSessionConfiguration = .init()) {
        self.url = url
        self.path = path
        self.configuration = configuration
        self.videoLayer = AVSampleBufferDisplayLayer()

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
            throw MoQSessionError.alreadyPlaying
        }

        transition(to: .connecting)

        do {
            // 1. Create origin
            let origin = try MoQOrigin()
            self.origin = origin

            // 2. Connect transport with consume origin
            let transport = try await MoQTransport.connect(url: url, consumeOrigin: origin.handle)
            self.transport = transport

            // 3. Set up A/V sync (once for the lifetime of the player)
            synchronizer.addRenderer(audioRenderer)
            videoLayer.controlTimebase = synchronizer.timebase

            // 4. Transport is ready — transition to connected
            transition(to: .connected)

            // 5. Monitor session status
            transportMonitorTask = Task { [weak self] in
                guard let self else { return }
                for await statusCode in transport.status {
                    if statusCode != 0 {
                        self.transition(to: .error("Session ended with code \(statusCode)"))
                        await self.close()
                        return
                    }
                }
            }

            // 6. Watch announcements — manages catalog subscription per active broadcast
            announcedTask = Task { [weak self] in
                guard let self else { return }
                guard let announcements = try? origin.announced() else { return }

                for await broadcast in announcements {
                    guard !Task.isCancelled else { break }
                    guard broadcast.path == self.path else { continue }

                    if broadcast.active {
                        // Tear down any existing tracks and catalog
                        await self.tearDownTracks()
                        self.catalogTask?.cancel()
                        self.catalogTask = nil
                        self.catalogSubscription = nil
                        self.currentCatalog = nil
                        self.currentBroadcastHandle = nil
                        if self.currentState == .playing {
                            self.transition(to: .connected)
                        }

                        do {
                            let handle = try origin.consume(path: self.path)
                            self.currentBroadcastHandle = handle

                            let subscription = try MoQCatalog.subscribeUpdates(broadcastHandle: handle)
                            self.catalogSubscription = subscription

                            self.catalogTask = Task { [weak self] in
                                guard let self else { return }
                                for await catalog in subscription.catalogs {
                                    guard !Task.isCancelled else { break }
                                    self.currentCatalog = catalog
                                    let info = self.buildBroadcastInfo(from: catalog)
                                    self.broadcastsContinuation.yield(.available(info))
                                }
                            }
                        } catch {
                            self.transition(to: .error("\(error)"))
                            await self.close()
                            return
                        }
                    } else {
                        // Broadcast went offline
                        self.catalogTask?.cancel()
                        self.catalogTask = nil
                        self.catalogSubscription = nil
                        self.currentCatalog = nil
                        self.currentBroadcastHandle = nil
                        await self.tearDownTracks()
                        if self.currentState == .playing {
                            self.transition(to: .connected)
                        }
                        self.broadcastsContinuation.yield(.unavailable)
                    }
                }
            }

        } catch let error as MoQError {
            transition(to: .error(error.description))
            await tearDown()
            throw MoQSessionError.connectionFailed(error)
        } catch let error as MoQSessionError {
            transition(to: .error("\(error)"))
            await tearDown()
            throw error
        } catch {
            transition(to: .error(error.localizedDescription))
            await tearDown()
            throw error
        }
    }

    /// Subscribe to specific video and/or audio tracks and begin playback.
    /// Replaces any currently active tracks.
    public func startTrack(videoIndex: UInt32? = nil, audioIndex: UInt32? = nil) async throws {
        guard currentBroadcastHandle != nil, let catalog = currentCatalog else {
            throw MoQSessionError.noBroadcastAvailable
        }
        guard videoIndex != nil || audioIndex != nil else {
            throw MoQSessionError.noTracksSelected
        }

        let broadcastHandle = currentBroadcastHandle!
        let maxLatencyMs = configuration.maxLatencyMs

        // Build format descriptions for requested indices
        var videoFmt: CMFormatDescription?
        var audioFmt: CMFormatDescription?

        if let vi = videoIndex, let vc = try? catalog.videoConfig(at: vi) {
            videoFmt = try? SampleBufferFactory.makeVideoFormatDescription(from: vc)
        }
        if let ai = audioIndex, let ac = try? catalog.audioConfig(at: ai) {
            audioFmt = try? SampleBufferFactory.makeAudioFormatDescription(from: ac)
        }

        // Stop any currently rendering tracks first
        await tearDownTracks()

        // Subscribe to new tracks
        if videoFmt != nil, let vi = videoIndex {
            self.videoTrack = try MoQVideoTrack.subscribe(
                broadcastHandle: broadcastHandle,
                index: vi,
                maxLatencyMs: maxLatencyMs
            )
        }
        if audioFmt != nil, let ai = audioIndex {
            self.audioTrack = try MoQAudioTrack.subscribe(
                broadcastHandle: broadcastHandle,
                index: ai,
                maxLatencyMs: maxLatencyMs
            )
        }

        // Fresh sync helpers per startTrack call
        let baseTimestamp = BaseTimestamp()
        let playbackStarted = PlaybackStartFlag()

        let layer = videoLayer
        let renderer = audioRenderer
        let sync = synchronizer

        if let vTrack = videoTrack, let vFmt = videoFmt {
            videoTask = Task.detached { [weak self] in
                for await frame in vTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: vFmt, baseTimestampUs: baseUs
                        )
                        layer.enqueue(sb)
                        if playbackStarted.setIfFirst() {
                            let player = self
                            await MainActor.run {
                                guard let player, player.currentState == .connected else { return }
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                                player.transition(to: .playing)
                            }
                        }
                    } catch {
                        continue
                    }
                }
            }
        }

        if let aTrack = audioTrack, let aFmt = audioFmt {
            audioTask = Task.detached { [weak self] in
                for await frame in aTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: aFmt, baseTimestampUs: baseUs
                        )
                        renderer.enqueue(sb)
                        if playbackStarted.setIfFirst() {
                            let player = self
                            await MainActor.run {
                                guard let player, player.currentState == .connected else { return }
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                                player.transition(to: .playing)
                            }
                        }
                    } catch {
                        continue
                    }
                }
            }
        }
    }

    /// Stop playback and release all resources.
    public func close() async {
        guard currentState != .closed else { return }
        await tearDown()
        transition(to: .closed)
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    deinit {
        videoTask?.cancel()
        audioTask?.cancel()
        transportMonitorTask?.cancel()
        announcedTask?.cancel()
        catalogTask?.cancel()
        stateContinuation.finish()
        broadcastsContinuation.finish()
    }

    // MARK: - Private

    private func transition(to newState: MoQSessionState) {
        currentState = newState
        stateContinuation.yield(newState)
    }

    /// Build a `MoQBroadcastInfo` by enumerating all video and audio configs in the catalog.
    private func buildBroadcastInfo(from catalog: MoQCatalog) -> MoQBroadcastInfo {
        var videoTracks: [MoQBroadcastTrack<VideoConfig>] = []
        var audioTracks: [MoQBroadcastTrack<AudioConfig>] = []

        var i: UInt32 = 0
        while let vc = try? catalog.videoConfig(at: i) {
            videoTracks.append(MoQBroadcastTrack<VideoConfig>(index: i, config: vc))
            i += 1
        }

        i = 0
        while let ac = try? catalog.audioConfig(at: i) {
            audioTracks.append(MoQBroadcastTrack<AudioConfig>(index: i, config: ac))
            i += 1
        }

        return MoQBroadcastInfo(videoTracks: videoTracks, audioTracks: audioTracks)
    }

    /// Tear down tracks and flush renderers without touching session or origin.
    private func tearDownTracks() async {
        videoTask?.cancel()
        audioTask?.cancel()
        videoTask = nil
        audioTask = nil

        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)

        await videoTrack?.close()
        videoTrack = nil
        await audioTrack?.close()
        audioTrack = nil
    }

    private func tearDown() async {
        videoTask?.cancel()
        audioTask?.cancel()
        transportMonitorTask?.cancel()
        announcedTask?.cancel()
        catalogTask?.cancel()
        videoTask = nil
        audioTask = nil
        transportMonitorTask = nil
        announcedTask = nil
        catalogTask = nil
        catalogSubscription = nil
        currentCatalog = nil
        currentBroadcastHandle = nil

        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)

        await videoTrack?.close()
        videoTrack = nil
        await audioTrack?.close()
        audioTrack = nil

        try? await transport?.close()
        transport = nil

        try? origin?.close()
        origin = nil
    }
}

// MARK: - BaseTimestamp

/// Thread-safe container for the first frame timestamp, shared between video and audio tasks.
private final class BaseTimestamp: @unchecked Sendable {
    private var value: UInt64?
    private let lock = NSLock()

    /// Returns the stored base timestamp. On first call, stores the provided timestamp as the base.
    func resolve(_ timestampUs: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let v = value { return v }
        value = timestampUs
        return timestampUs
    }
}

// MARK: - PlaybackStartFlag

/// Thread-safe one-shot flag ensuring only the first frame triggers playback start.
private final class PlaybackStartFlag: @unchecked Sendable {
    private var started = false
    private let lock = NSLock()

    /// Returns `true` exactly once (the first call), `false` on all subsequent calls.
    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }
}
