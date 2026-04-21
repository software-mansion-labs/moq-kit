import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - PlaybackStats

/// A snapshot of playback quality metrics, sampled over the most recent one-second window.
///
/// Obtain the current snapshot via ``Player/stats``, which is safe to call from any
/// thread or actor without holding the main actor.
public struct PlaybackStats: Sendable {
    /// Estimated end-to-end audio latency in milliseconds (wall-clock delay from sender to speaker).
    /// `nil` when no audio track is active.
    public let audioLatencyMs: Double?
    /// Estimated end-to-end video latency in milliseconds.
    /// `nil` when no video track is active.
    public let videoLatencyMs: Double?

    /// Audio stall statistics since playback started. `nil` when no audio track is active.
    public let audioStalls: StallStats?
    /// Video stall statistics since playback started. `nil` when no video track is active.
    public let videoStalls: StallStats?

    /// Audio bitrate of the incoming stream in kilobits per second. `nil` when no audio track is active.
    public let audioBitrateKbps: Double?
    /// Video bitrate of the incoming stream in kilobits per second. `nil` when no video track is active.
    public let videoBitrateKbps: Double?

    /// Time from ``Player/play()`` to the first decoded audio frame, in milliseconds.
    /// `nil` before the first frame arrives or when no audio track is active.
    public let timeToFirstAudioFrameMs: Double?
    /// Time from ``Player/play()`` to the first decoded video frame, in milliseconds.
    /// `nil` before the first frame arrives or when no video track is active.
    public let timeToFirstVideoFrameMs: Double?

    /// Current video frame rate in frames per second. `nil` when no video track is active.
    public let videoFps: Double?

    /// Total audio frames dropped since playback started. `nil` when no audio track is active.
    public let audioFramesDropped: UInt64?
    /// Total video frames dropped since playback started. `nil` when no video track is active.
    public let videoFramesDropped: UInt64?

    /// Current audio ring buffer fill level in milliseconds. Reflects how much audio is
    /// buffered ahead of the playhead. `nil` when no audio track is active.
    public let audioRingBufferMs: Double?
    /// Current video jitter buffer fill level in milliseconds. `nil` when no video track is active.
    public let videoJitterBufferMs: Double?
}

/// Stall statistics for a single track since playback started.
public struct StallStats: Sendable {
    /// Number of stall events (playback interruptions) since playback started.
    public let count: UInt64
    /// Total cumulative duration of all stall events in milliseconds.
    public let totalDurationMs: Double
    /// Fraction of playback time spent stalling: `totalDurationMs / totalPlaybackDurationMs`.
    public let rebufferingRatio: Double
}

// MARK: - PlayerEvent

/// Events emitted on ``Player/events`` during playback.
public enum PlayerEvent: Sendable {
    /// The first frame of the given track kind was successfully decoded and rendered.
    case trackPlaying(TrackKind)
    /// Playback of the given track kind was paused via ``Player/pause()``.
    case trackPaused(TrackKind)
    /// The remote sender stopped the given track (the track stream ended).
    case trackStopped(TrackKind)
    /// All active tracks have stopped. The events stream completes immediately after this event.
    case allTracksStopped
    /// A non-fatal error occurred on the given track. Playback of other tracks continues.
    case error(TrackKind, String)
    /// The first frame of a switched-in rendition was rendered. Emitted after a successful
    /// ``Player/switchTrack(to:)-7ugy3`` or ``Player/switchTrack(to:)-3kgck`` call.
    case trackSwitched(TrackKind)

    /// Identifies which type of media track an event relates to.
    public enum TrackKind: String, Sendable {
        case video, audio
    }
}

// MARK: - Player

/// Adaptive real-time player for MoQ media streams.
///
/// `Player` subscribes to one or two tracks from a ``BroadcastInfo`` (one video and/or
/// one audio track), decodes the incoming frames, and renders them in sync:
///
/// - Video frames are rendered into ``videoLayer`` — an `AVSampleBufferDisplayLayer` you can
///   embed in any `UIView` or `CALayer` hierarchy.
/// - Audio frames are decoded to PCM and played through `AVAudioEngine` using the system's
///   default audio output. No additional audio session configuration is required.
///
/// ```swift
/// let player = try Player(tracks: broadcastInfo.videoTracks + broadcastInfo.audioTracks)
/// view.layer.addSublayer(player.videoLayer)
/// try await player.play()
/// ```
///
/// The class is `@MainActor` — all calls must be made from the main actor.
@MainActor
public final class Player {
    /// The `AVSampleBufferDisplayLayer` that receives decoded video frames.
    ///
    /// Add this layer to your view hierarchy before calling ``play()``.
    public let videoLayer: AVSampleBufferDisplayLayer
    /// Emits ``PlayerEvent`` values as playback progresses.
    ///
    /// The stream completes after ``allTracksStopped`` is emitted or after ``stopAll()`` is called.
    public let events: AsyncStream<PlayerEvent>

    private let tracks: [any TrackInfo]
    private var targetBufferingMs: UInt64
    private let eventsContinuation: AsyncStream<PlayerEvent>.Continuation

    private var audioRenderer: AudioRenderer?
    private var videoRenderer: VideoRenderer?
    private var videoRendererTrack: VideoRendererTrack?

    private var videoSubscription: MediaTrack?
    private var audioSubscription: MediaTrack?

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?

    nonisolated(unsafe) private var audioTracer: PacketTimingTracer?
    nonisolated(unsafe) private var videoTracer: PacketTimingTracer?
    nonisolated(unsafe) private var audioRendererForStats: AudioRenderer?
    nonisolated(unsafe) private var videoRendererForStats: VideoRenderer?

    private let accumulator = PlaybackMetricsAccumulator()
    private let mode: Mode

    private enum Mode {
        case audioVideo
        case audioOnly
        case videoOnly
    }

    private nonisolated var hasVideoTrack: Bool {
        tracks.contains(where: { $0 is VideoTrackInfo })
    }
    private nonisolated var hasAudioTrack: Bool {
        tracks.contains(where: { $0 is AudioTrackInfo })
    }

    /// Creates a player for the given tracks.
    ///
    /// - Parameters:
    ///   - tracks: One or two ``TrackInfo`` values from ``BroadcastInfo``. Pass at most one
    ///     video track and one audio track. Mixing two video or two audio tracks is not supported.
    ///   - targetBufferingMs: Target playout delay in milliseconds. Higher values improve
    ///     resilience to network jitter at the cost of increased end-to-end latency. Defaults
    ///     to 100 ms. Can be adjusted live via ``updateTargetLatency(ms:)``.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if `tracks` is empty or contains
    ///   more than two entries.
    public init(
        tracks: [any TrackInfo],
        targetBufferingMs: UInt64 = 100
    ) throws {
        if tracks.isEmpty || tracks.count > 2 {
            throw SessionError.invalidConfiguration("expected one or two tracks")
        }

        self.tracks = tracks
        self.targetBufferingMs = targetBufferingMs
        self.videoLayer = AVSampleBufferDisplayLayer()

        let hasVideo = tracks.contains(where: { $0 is VideoTrackInfo })
        let hasAudio = tracks.contains(where: { $0 is AudioTrackInfo })
        if hasVideo && hasAudio {
            mode = .audioVideo
        } else if hasAudio {
            mode = .audioOnly
        } else {
            mode = .videoOnly
        }

        var cont: AsyncStream<PlayerEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
    }

    // MARK: - Public API

    /// Adjusts the target playout delay without interrupting playback.
    ///
    /// The change takes effect immediately on both the audio ring buffer and the video jitter
    /// buffer. Lowering the value reduces latency but increases the risk of stalls on lossy
    /// networks; raising it improves resilience.
    ///
    /// - Parameter ms: New target buffering depth in milliseconds.
    public func updateTargetLatency(ms: UInt64) {
        targetBufferingMs = ms
        audioRenderer?.updateTargetLatency(ms: Int(ms))
        videoRendererTrack?.updateTargetBuffering(ms: ms)
    }

    /// A snapshot of current playback quality metrics.
    ///
    /// Safe to call from any thread or actor — does not require the main actor.
    /// Values are sampled over the most recent one-second window. See ``PlaybackStats``
    /// for field-level documentation.
    public nonisolated var stats: PlaybackStats {
        accumulator.snapshot(
            audioLatencyMs: hasAudioTrack ? audioTracer?.latencyMs : nil,
            videoLatencyMs: hasVideoTrack ? videoTracer?.latencyMs : nil,
            audioRingBufferMs: audioRendererForStats?.bufferFillMs,
            videoJitterBufferMs: videoRendererForStats?.bufferFillMs
        )
    }

    /// Subscribes to the selected tracks and begins decoding and rendering.
    ///
    /// Playback events are emitted on ``events``. Call ``pause()`` to temporarily suspend
    /// rendering without releasing the track subscriptions, or ``stopAll()`` to fully tear down.
    ///
    /// - Throws: ``SessionError`` if a track subscription or renderer initialisation fails.
    public func play() async throws {
        guard videoTask == nil && audioTask == nil else { return }

        try subscribe()

        let timebase = try Self.createTimebase()

        if hasAudioTrack {
            audioTracer = PacketTimingTracer(kind: .audio, timebase: timebase) { report in
                KitLogger.player.debug("\(report)")
            }
        }
        if hasVideoTrack {
            videoTracer = PacketTimingTracer(kind: .video, timebase: timebase) { report in
                KitLogger.player.debug("\(report)")
            }
        }

        accumulator.markPlayStart()

        try setupAudioRenderer(timebase: timebase)
        setupVideoRenderer(timebase: timebase)

        startIngestTasks()
    }

    /// Pauses playback and cancels all track subscriptions.
    ///
    /// Emits ``PlayerEvent/trackPaused(_:)`` for each active track. To resume, call
    /// ``play()`` again — it will re-subscribe to the tracks and restart rendering from the
    /// current live position.
    public func pause() async {
        teardown(permanent: false)

        if hasVideoTrack {
            eventsContinuation.yield(.trackPaused(.video))
        }
        if hasAudioTrack {
            eventsContinuation.yield(.trackPaused(.audio))
        }
    }

    /// Stops playback, closes all track subscriptions, and releases all rendering resources.
    ///
    /// The ``events`` stream completes after this call. The player cannot be reused — create a
    /// new ``Player`` instance to start playback again.
    public func stopAll() async {
        KitLogger.player.debug("Stopping real-time player")
        teardown(permanent: true)
    }

    /// Switches to a different video rendition seamlessly.
    ///
    /// The new subscription is started in parallel with the old one. The old track keeps
    /// feeding the jitter buffer until the new rendition delivers its first frame, at which
    /// point the old ingest task is cancelled. No flush occurs — the jitter buffer provides
    /// continuity, and `AVSampleBufferDisplayLayer` handles per-frame format description
    /// changes natively.
    ///
    /// Emits ``PlayerEvent/trackSwitched(_:)`` when the first frame of the new rendition
    /// is rendered.
    ///
    /// - Parameter track: A ``VideoTrackInfo`` from the same broadcast.
    /// - Throws: ``SessionError`` if subscribing to the new track fails.
    public func switchTrack(to track: VideoTrackInfo) async throws {
        guard videoTask != nil, let renderer = videoRenderer, !renderer.hasPendingTrack else { return }

        KitLogger.player.debug("Switching video track to \(track.name)")

        let newSub = try MediaTrack(
            broadcast: track.broadcast,
            name: track.name,
            container: track.rawConfig.container,
            maxLatencyMs: targetBufferingMs)
        
        KitLogger.player.debug(
            "[Switch] Video track: \(track.name), codec=\(track.config.codec), config=\(track.config.debugDescription), container=\(track.rawConfig.container)"
        )

        let newTrack = try VideoRendererTrack(
            config: track.rawConfig,
            targetBufferingMs: targetBufferingMs)

        let oldTask = videoTask
        let oldSub = videoSubscription
        let continuation = eventsContinuation

        let newTracer = PacketTimingTracer(kind: .video, timebase: renderer.timebase) { report in
            KitLogger.player.debug("\(report)")
        }

        renderer.setPendingTrack(newTrack) {
            // Called on enqueueQueue when the renderer promotes the pending track.
            oldTask?.cancel()
            oldSub?.close()
            continuation.yield(.trackSwitched(.video))
        }

        // Update videoTracer on the main actor — the new ingest task already captures
        // newTracer directly, so stats will reflect the new rendition from this point on.
        videoTracer = newTracer

        videoSubscription = newSub
        videoRendererTrack = newTrack
        videoTask = startVideoIngestTask(
            subscription: newSub, track: newTrack,
            tracer: newTracer, isSwitch: true)

        restartCoordinator()
    }

    /// Switches to a different audio rendition seamlessly.
    ///
    /// The new ingest task is started immediately; the old one is cancelled right after.
    /// The ring buffer's timestamp-based write positioning means both decoders briefly
    /// write identical PCM to the same positions — there is no audible glitch, and no
    /// ring buffer reset is needed.
    ///
    /// Emits ``PlayerEvent/trackSwitched(_:)`` when the first frame of the new rendition
    /// is rendered.
    ///
    /// - Parameter track: A ``AudioTrackInfo`` from the same broadcast.
    /// - Throws: ``SessionError`` if subscribing to the new track fails.
    public func switchTrack(to track: AudioTrackInfo) async throws {
        guard audioTask != nil else { return }

        KitLogger.player.debug("Switching audio track to \(track.name)")

        let newSub = try MediaTrack(
            broadcast: track.broadcast,
            name: track.name,
            container: track.rawConfig.container,
            maxLatencyMs: targetBufferingMs)

        let oldTask = audioTask
        let oldSub = audioSubscription

        audioSubscription = newSub
        audioTask = startAudioIngestTask(subscription: newSub, config: track.rawConfig, isSwitch: true)

        // Cancel old task immediately — the ring buffer provides continuity via
        // timestamp-based positioning (same timestamps → same ring buffer slots).
        oldTask?.cancel()
        oldSub?.close()

        restartCoordinator()
    }

    deinit {
        videoTask?.cancel()
        audioTask?.cancel()
        coordinatorTask?.cancel()
        eventsContinuation.finish()
    }

    // MARK: - Private: teardown

    private func teardown(permanent: Bool) {
        videoTask?.cancel()
        audioTask?.cancel()
        coordinatorTask?.cancel()
        videoTask = nil
        audioTask = nil
        coordinatorTask = nil

        audioRenderer?.stop()
        videoRenderer?.stop()
        videoRenderer?.flush()

        audioTracer?.reset()
        videoTracer?.reset()

        videoSubscription?.close()
        audioSubscription?.close()
        videoSubscription = nil
        audioSubscription = nil

        if permanent {
            audioRenderer = nil
            videoRenderer = nil
            videoRendererTrack = nil
            audioTracer = nil
            videoTracer = nil
            audioRendererForStats = nil
            videoRendererForStats = nil
            accumulator.reset()

            eventsContinuation.finish()
        }
    }

    // MARK: - Private: play() helpers

    private nonisolated static func createTimebase() throws -> CMTimebase {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard let tb else {
            throw SessionError.invalidConfiguration("Failed to create CMTimebase")
        }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 0)
        return tb
    }

    private func setupAudioRenderer(timebase: CMTimebase) throws {
        guard let aInfo = tracks.compactMap({ $0 as? AudioTrackInfo }).first else {
            return
        }

        let renderer = try AudioRenderer(
            config: aInfo.rawConfig,
            timebase: timebase,
            targetLatencyMs: Int(targetBufferingMs),
            metrics: accumulator
        )
        try renderer.start()
        self.audioRenderer = renderer
        self.audioRendererForStats = renderer
    }

    private func setupVideoRenderer(timebase: CMTimebase) {
        guard let vInfo = tracks.compactMap({ $0 as? VideoTrackInfo }).first else { return }

        let track: VideoRendererTrack
        do {
            track = try VideoRendererTrack(
                config: vInfo.rawConfig, targetBufferingMs: targetBufferingMs)
        } catch {
            KitLogger.player.error("Failed to create VideoRendererTrack: \(error)")
            return
        }

        let renderer = VideoRenderer(
            timebase: timebase,
            isTimebaseOwner: mode == .videoOnly,
            track: track,
            layer: videoLayer,
            metrics: accumulator
        )
        renderer.start()
        self.videoRendererTrack = track
        self.videoRenderer = renderer
        self.videoRendererForStats = renderer
    }

    private func startIngestTasks() {
        if let aTrack = audioSubscription, let aConfig = tracks.compactMap({ $0 as? AudioTrackInfo }).first?.rawConfig {
            audioTask = startAudioIngestTask(subscription: aTrack, config: aConfig, isSwitch: false)
        }

        if let vTrack = videoSubscription, let rendererTrack = videoRendererTrack {
            videoTask = startVideoIngestTask(
                subscription: vTrack, track: rendererTrack,
                tracer: videoTracer, isSwitch: false)
        }

        restartCoordinator()
    }

    // MARK: - Private: per-track ingest tasks

    private func startVideoIngestTask(
        subscription: MediaTrack,
        track: VideoRendererTrack,
        tracer: PacketTimingTracer?,
        isSwitch: Bool
    ) -> Task<Void, Never> {
        let continuation = eventsContinuation
        let metrics = self.accumulator

        return Task.detached {
            var lastPtsUs: UInt64 = 0
            var firstFrame = true
            
            defer {
                KitLogger.player.debug("Exited reading task")
            }

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                if Self.isDiscontinuity(
                    currentUs: frame.timestampUs, lastUs: lastPtsUs,
                    keyframe: frame.keyframe
                ) {
                    KitLogger.player.debug("Video discontinuity detected")
                    tracer?.reset()
                }
                lastPtsUs = frame.timestampUs

                metrics.recordVideoBytes(frame.payload.count)
                tracer?.record(ptsUs: frame.timestampUs)

                track.insert(
                    payload: frame.payload,
                    timestampUs: frame.timestampUs,
                    keyframe: frame.keyframe)

                if firstFrame && !isSwitch {
                    firstFrame = false
                    metrics.markFirstVideoFrame()
                    continuation.yield(.trackPlaying(.video))
                } else if firstFrame {
                    firstFrame = false
                    metrics.markFirstVideoFrame()
                }
            }
            if !Task.isCancelled {
                continuation.yield(.trackStopped(.video))
            }
        }
    }

    private func startAudioIngestTask(
        subscription: MediaTrack,
        config: MoqAudio,
        isSwitch: Bool
    ) -> Task<Void, Never> {
        let continuation = eventsContinuation
        let audioTracer = self.audioTracer
        let metrics = self.accumulator
        guard let renderer = self.audioRenderer else {
            KitLogger.player.error("startAudioIngestTask called without an active AudioRenderer")
            return Task.detached {}
        }

        return Task.detached {
            let decoder: AudioDecoder
            do {
                decoder = try AudioDecoder(config: config)
            } catch {
                KitLogger.player.error("Failed to create AudioDecoder: \(error)")
                continuation.yield(.error(.audio, error.localizedDescription))
                return
            }

            var lastPtsUs: UInt64 = 0
            var firstFrame = true

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                do {
                    if Self.isDiscontinuity(
                        currentUs: frame.timestampUs, lastUs: lastPtsUs,
                        keyframe: frame.keyframe
                    ) {
                        KitLogger.player.debug("Audio discontinuity detected, flushing")
                        renderer.flush()
                        audioTracer?.reset()
                    }
                    lastPtsUs = frame.timestampUs

                    metrics.recordAudioBytes(frame.payload.count)
                    audioTracer?.record(ptsUs: frame.timestampUs)
                    let pcm = try decoder.decode(payload: frame.payload)
                    renderer.enqueue(pcm: pcm, timestampUs: frame.timestampUs)

                    if firstFrame {
                        firstFrame = false
                        metrics.markFirstAudioFrame()
                        let event: PlayerEvent = isSwitch ? .trackSwitched(.audio) : .trackPlaying(.audio)
                        continuation.yield(event)
                    }
                } catch {
                    KitLogger.player.error("Audio decode error: \(error)")
                    continuation.yield(.error(.audio, error.localizedDescription))
                }
            }
            if !Task.isCancelled {
                continuation.yield(.trackStopped(.audio))
            }
        }
    }

    private func restartCoordinator() {
        coordinatorTask?.cancel()
        let vTask = videoTask
        let aTask = audioTask
        let continuation = eventsContinuation
        coordinatorTask = Task.detached {
            await vTask?.value
            await aTask?.value
            guard !Task.isCancelled else { return }
            continuation.yield(.allTracksStopped)
            continuation.finish()
        }
    }

    // MARK: - Private: helpers

    /// Detects a PTS discontinuity: keyframe with >500ms jump from the last timestamp.
    private nonisolated static func isDiscontinuity(
        currentUs: UInt64, lastUs: UInt64, keyframe: Bool
    ) -> Bool {
        guard keyframe && lastUs > 0 else { return false }
        let diff =
            currentUs > lastUs
            ? currentUs - lastUs
            : lastUs - currentUs
        return diff > 500_000
    }

    private func subscribe() throws {
        for track in tracks {
            if let vInfo = track as? VideoTrackInfo {
                KitLogger.player.debug(
                    "Video track: \(vInfo.name), codec=\(vInfo.config.codec), config=\(vInfo.config.debugDescription), container=\(vInfo.rawConfig.container)"
                )
                do {
                    videoSubscription = try MediaTrack(
                        broadcast: vInfo.broadcast, name: vInfo.name,
                        container: vInfo.rawConfig.container,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    KitLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.name): \(error)")
                }
            } else if let aInfo = track as? AudioTrackInfo {
                KitLogger.player.debug(
                    "Audio track: \(aInfo.name), config = \(aInfo.config.debugDescription), container=\(aInfo.rawConfig.container)"
                )
                do {
                    audioSubscription = try MediaTrack(
                        broadcast: aInfo.broadcast, name: aInfo.name,
                        container: aInfo.rawConfig.container,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    KitLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.name): \(error)")
                }
            }
        }
    }

}
