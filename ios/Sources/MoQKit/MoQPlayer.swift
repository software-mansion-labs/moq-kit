import AVFoundation
import CoreMedia

// MARK: - State

public enum MoQPlayerState: Sendable, Equatable {
    case idle
    case connecting
    case playing
    case error(String)
    case closed
}

// MARK: - Configuration

public struct MoQPlayerConfiguration: Sendable {
    public var maxLatencyMs: UInt64
    public var videoTrackIndex: UInt32
    public var audioTrackIndex: UInt32

    public init(
        maxLatencyMs: UInt64 = 500,
        videoTrackIndex: UInt32 = 0,
        audioTrackIndex: UInt32 = 0
    ) {
        self.maxLatencyMs = maxLatencyMs
        self.videoTrackIndex = videoTrackIndex
        self.audioTrackIndex = audioTrackIndex
    }
}

// MARK: - MoQPlayer

@MainActor
public final class MoQPlayer {
    /// Add this layer to your view hierarchy for video display.
    public let videoLayer: AVSampleBufferDisplayLayer

    /// Observe state changes.
    public let state: AsyncStream<MoQPlayerState>

    private let url: String
    private let path: String
    private let configuration: MoQPlayerConfiguration

    private let stateContinuation: AsyncStream<MoQPlayerState>.Continuation
    private var currentState: MoQPlayerState = .idle

    // Pipeline objects
    private var origin: MoQOrigin?
    private var session: MoQSession?
    private var broadcastHandle: UInt32?
    private var catalog: MoQCatalog?
    private var videoTrack: MoQVideoTrack?
    private var audioTrack: MoQAudioTrack?

    // AVFoundation
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    // Background tasks
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var sessionMonitorTask: Task<Void, Never>?

    public init(url: String, path: String, configuration: MoQPlayerConfiguration = .init()) {
        self.url = url
        self.path = path
        self.configuration = configuration
        self.videoLayer = AVSampleBufferDisplayLayer()

        var cont: AsyncStream<MoQPlayerState>.Continuation!
        self.state = AsyncStream { cont = $0 }
        self.stateContinuation = cont

        stateContinuation.yield(.idle)
    }

    /// Connect, subscribe to tracks, and begin playback.
    public func play() async throws {
        guard currentState == .idle else {
            if currentState == .closed { throw MoQPlayerError.alreadyClosed }
            throw MoQPlayerError.alreadyPlaying
        }

        transition(to: .connecting)

        do {
            // 1. Create origin
            let origin = try MoQOrigin()
            self.origin = origin

            // 2. Connect session with consume origin
            let session = try await MoQSession.connect(url: url, consumeOrigin: origin.handle)
            self.session = session

            // 3. Wait for server to announce path, then consume
            let broadcastHandle = try await origin.consume(waitingForPath: "anon/bbb")
            self.broadcastHandle = broadcastHandle

            // 4. Subscribe to catalog
            let catalog = try await MoQCatalog.subscribe(broadcastHandle: broadcastHandle)
            self.catalog = catalog

            // 5. Build format descriptions from codec configs
            var videoFmt: CMFormatDescription?
            var audioFmt: CMFormatDescription?

            if let vc = try? catalog.videoConfig(at: configuration.videoTrackIndex) {
                videoFmt = try? SampleBufferFactory.makeVideoFormatDescription(from: vc)
            }

            if let ac = try? catalog.audioConfig(at: configuration.audioTrackIndex) {
                audioFmt = try? SampleBufferFactory.makeAudioFormatDescription(from: ac)
            }

            guard videoFmt != nil && audioFmt != nil else {
                throw MoQPlayerError.noTracksAvailable
            }

            // 6. Subscribe to tracks
            if videoFmt != nil {
                self.videoTrack = try MoQVideoTrack.subscribe(
                    broadcastHandle: broadcastHandle,
                    index: configuration.videoTrackIndex,
                    maxLatencyMs: configuration.maxLatencyMs
                )
            }
            if audioFmt != nil {
                self.audioTrack = try MoQAudioTrack.subscribe(
                    broadcastHandle: broadcastHandle,
                    index: configuration.audioTrackIndex,
                    maxLatencyMs: configuration.maxLatencyMs
                )
            }

            // 7. Set up A/V sync
            synchronizer.addRenderer(audioRenderer)
            videoLayer.controlTimebase = synchronizer.timebase

            // 8. Spawn frame-processing tasks
            let layer = videoLayer
            let renderer = audioRenderer
            let sync = synchronizer
            let baseTimestamp = BaseTimestamp()
            let playbackStarted = PlaybackStartFlag()

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
                                    guard let player, player.currentState == .connecting else { return }
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
                                    guard let player, player.currentState == .connecting else { return }
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

            // 9. Monitor session status
            sessionMonitorTask = Task { [weak self] in
                guard let self else { return }
                for await statusCode in session.status {
                    if statusCode != 0 {
                        self.transition(to: .error("Session ended with code \(statusCode)"))
                        self.close()
                        return
                    }
                }
            }

        } catch let error as MoQError {
            transition(to: .error(error.description))
            tearDown()
            throw MoQPlayerError.connectionFailed(error)
        } catch let error as MoQPlayerError {
            transition(to: .error("\(error)"))
            tearDown()
            throw error
        } catch {
            transition(to: .error(error.localizedDescription))
            tearDown()
            throw error
        }
    }

    /// Stop playback and release all resources.
    public func close() {
        guard currentState != .closed else { return }
        tearDown()
        transition(to: .closed)
        stateContinuation.finish()
    }

    deinit {
        videoTask?.cancel()
        audioTask?.cancel()
        sessionMonitorTask?.cancel()
        stateContinuation.finish()
    }

    // MARK: - Private

    private func transition(to newState: MoQPlayerState) {
        currentState = newState
        stateContinuation.yield(newState)
    }

    private func tearDown() {
        // 1. Cancel background tasks
        videoTask?.cancel()
        audioTask?.cancel()
        sessionMonitorTask?.cancel()
        videoTask = nil
        audioTask = nil
        sessionMonitorTask = nil

        // 2. Flush AVFoundation renderers
        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)

        // 3. Close tracks
        videoTrack?.close()
        videoTrack = nil
        audioTrack?.close()
        audioTrack = nil

        // 4. Close catalog
        catalog?.close()
        catalog = nil

        // 5. Close broadcast consumer
        if let bh = broadcastHandle {
            try? closeBroadcastConsumer(bh)
            broadcastHandle = nil
        }

        // 6. Close session
        try? session?.close()
        session = nil

        // 7. Close origin
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
