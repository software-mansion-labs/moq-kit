import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - PlaybackStats

/// A snapshot of playback quality metrics, sampled over the most recent one-second window.
///
/// Obtain the current snapshot via ``MoQPlayer/stats``, which is safe to call from any
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

    /// Time from ``MoQPlayer/play()`` to the first decoded audio frame, in milliseconds.
    /// `nil` before the first frame arrives or when no audio track is active.
    public let timeToFirstAudioFrameMs: Double?
    /// Time from ``MoQPlayer/play()`` to the first decoded video frame, in milliseconds.
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

// MARK: - MoQPlayerEvent

/// Events emitted on ``MoQPlayer/events`` during playback.
public enum MoQPlayerEvent: Sendable {
    /// The first frame of the given track kind was successfully decoded and rendered.
    case trackPlaying(TrackKind)
    /// Playback of the given track kind was paused via ``MoQPlayer/pause()``.
    case trackPaused(TrackKind)
    /// The remote sender stopped the given track (the track stream ended).
    case trackStopped(TrackKind)
    /// All active tracks have stopped. The events stream completes immediately after this event.
    case allTracksStopped
    /// A non-fatal error occurred on the given track. Playback of other tracks continues.
    case error(TrackKind, String)

    /// Identifies which type of media track an event relates to.
    public enum TrackKind: String, Sendable {
        case video, audio
    }
}

// MARK: - MoQPlayer

/// Adaptive real-time player for MoQ media streams.
///
/// `MoQPlayer` subscribes to one or two tracks from a ``MoQBroadcastInfo`` (one video and/or
/// one audio track), decodes the incoming frames, and renders them in sync:
///
/// - Video frames are rendered into ``videoLayer`` — an `AVSampleBufferDisplayLayer` you can
///   embed in any `UIView` or `CALayer` hierarchy.
/// - Audio frames are decoded to PCM and played through `AVAudioEngine` using the system's
///   default audio output. No additional audio session configuration is required.
///
/// ```swift
/// let player = try MoQPlayer(tracks: broadcastInfo.videoTracks + broadcastInfo.audioTracks)
/// view.layer.addSublayer(player.videoLayer)
/// try await player.play()
/// ```
///
/// The class is `@MainActor` — all calls must be made from the main actor.
@MainActor
public final class MoQPlayer {
    /// The `AVSampleBufferDisplayLayer` that receives decoded video frames.
    ///
    /// Add this layer to your view hierarchy before calling ``play()``.
    public let videoLayer: AVSampleBufferDisplayLayer
    /// Emits ``MoQPlayerEvent`` values as playback progresses.
    ///
    /// The stream completes after ``allTracksStopped`` is emitted or after ``stopAll()`` is called.
    public let events: AsyncStream<MoQPlayerEvent>

    private let tracks: [any MoQTrackInfo]
    private var targetBufferingMs: UInt64
    private let eventsContinuation: AsyncStream<MoQPlayerEvent>.Continuation

    private var audioRenderer: AudioRenderer?
    private var videoRenderer: VideoRenderer?

    private var videoSubscription: MoQMediaTrack?
    private var audioSubscription: MoQMediaTrack?

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
        tracks.contains(where: { $0 is MoQVideoTrackInfo })
    }
    private nonisolated var hasAudioTrack: Bool {
        tracks.contains(where: { $0 is MoQAudioTrackInfo })
    }

    /// Creates a player for the given tracks.
    ///
    /// - Parameters:
    ///   - tracks: One or two ``MoQTrackInfo`` values from ``MoQBroadcastInfo``. Pass at most one
    ///     video track and one audio track. Mixing two video or two audio tracks is not supported.
    ///   - targetBufferingMs: Target playout delay in milliseconds. Higher values improve
    ///     resilience to network jitter at the cost of increased end-to-end latency. Defaults
    ///     to 100 ms. Can be adjusted live via ``updateTargetLatency(ms:)``.
    /// - Throws: ``MoQSessionError/invalidConfiguration(_:)`` if `tracks` is empty or contains
    ///   more than two entries.
    public init(
        tracks: [any MoQTrackInfo],
        targetBufferingMs: UInt64 = 100
    ) throws {
        if tracks.isEmpty || tracks.count > 2 {
            throw MoQSessionError.invalidConfiguration("expected one or two tracks")
        }

        self.tracks = tracks
        self.targetBufferingMs = targetBufferingMs
        self.videoLayer = AVSampleBufferDisplayLayer()

        let hasVideo = tracks.contains(where: { $0 is MoQVideoTrackInfo })
        let hasAudio = tracks.contains(where: { $0 is MoQAudioTrackInfo })
        if hasVideo && hasAudio {
            mode = .audioVideo
        } else if hasAudio {
            mode = .audioOnly
        } else {
            mode = .videoOnly
        }

        var cont: AsyncStream<MoQPlayerEvent>.Continuation!
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
        videoRenderer?.updateTargetBuffering(ms: ms)
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
    /// - Throws: ``MoQSessionError`` if a track subscription or renderer initialisation fails.
    public func play() async throws {
        guard videoTask == nil && audioTask == nil else { return }

        try subscribe()

        let timebase = try Self.createTimebase()

        if hasAudioTrack {
            audioTracer = PacketTimingTracer(kind: .audio, timebase: timebase) { report in
                MoQLogger.player.debug("\(report)")
            }
        }
        if hasVideoTrack {
            videoTracer = PacketTimingTracer(kind: .video, timebase: timebase) { report in
                MoQLogger.player.debug("\(report)")
            }
        }

        accumulator.markPlayStart()

        try setupAudioRenderer(timebase: timebase)
        try setupVideoRenderer(timebase: timebase)

        startIngestTasks()
    }

    /// Pauses playback and cancels all track subscriptions.
    ///
    /// Emits ``MoQPlayerEvent/trackPaused(_:)`` for each active track. To resume, call
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
    /// new ``MoQPlayer`` instance to start playback again.
    public func stopAll() async {
        MoQLogger.player.debug("Stopping real-time player")
        teardown(permanent: true)
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
            throw MoQSessionError.invalidConfiguration("Failed to create CMTimebase")
        }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 0)
        return tb
    }

    private func setupAudioRenderer(timebase: CMTimebase) throws {
        guard let aInfo = tracks.compactMap({ $0 as? MoQAudioTrackInfo }).first else {
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

    private func setupVideoRenderer(timebase: CMTimebase) throws {
        guard let vInfo = tracks.compactMap({ $0 as? MoQVideoTrackInfo }).first else {
            return
        }

        let renderer = try VideoRenderer(
            config: vInfo.rawConfig,
            timebase: timebase,
            isTimebaseOwner: mode == .videoOnly,
            targetBufferingMs: targetBufferingMs,
            layer: videoLayer,
            metrics: accumulator
        )
        renderer.start()
        self.videoRenderer = renderer
        self.videoRendererForStats = renderer
    }

    private func startIngestTasks() {
        let continuation = eventsContinuation
        let audioTracer = self.audioTracer
        let videoTracer = self.videoTracer
        let metrics = self.accumulator

        // Audio ingest task
        if let aTrack = audioSubscription, let renderer = audioRenderer {
            audioTask = Task.detached {
                var lastPtsUs: UInt64 = 0
                var firstFrame = true
                for await frame in aTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        if Self.isDiscontinuity(
                            currentUs: frame.timestampUs, lastUs: lastPtsUs,
                            keyframe: frame.keyframe
                        ) {
                            MoQLogger.player.debug(
                                "Audio discontinuity detected, flushing")
                            renderer.flush()
                            audioTracer?.reset()
                        }
                        lastPtsUs = frame.timestampUs

                        metrics.recordAudioBytes(frame.payload.count)
                        audioTracer?.record(ptsUs: frame.timestampUs)
                        let pcm = try renderer.decoder.decode(payload: frame.payload)
                        renderer.enqueue(pcm: pcm, timestampUs: frame.timestampUs)

                        if firstFrame {
                            firstFrame = false
                            metrics.markFirstAudioFrame()
                            continuation.yield(.trackPlaying(.audio))
                        }
                    } catch {
                        MoQLogger.player.error("Audio decode error: \(error)")
                        continuation.yield(.error(.audio, error.localizedDescription))
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(.trackStopped(.audio))
                }
            }
        }

        // Video ingest task
        if let vTrack = videoSubscription, let renderer = videoRenderer, renderer.canProcess {
            videoTask = Task.detached {
                var lastPtsUs: UInt64 = 0
                var firstFrame = true
                for await frame in vTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        if Self.isDiscontinuity(
                            currentUs: frame.timestampUs, lastUs: lastPtsUs,
                            keyframe: frame.keyframe
                        ) {
                            MoQLogger.player.debug(
                                "Video discontinuity detected, flushing")
                            renderer.flush()
                            videoTracer?.reset()
                        }
                        lastPtsUs = frame.timestampUs

                        metrics.recordVideoBytes(frame.payload.count)
                        videoTracer?.record(ptsUs: frame.timestampUs)
                        let inserted = try renderer.insert(
                            payload: frame.payload, timestampUs: frame.timestampUs,
                            keyframe: frame.keyframe)

                        if inserted && firstFrame {
                            firstFrame = false
                            metrics.markFirstVideoFrame()
                            continuation.yield(.trackPlaying(.video))
                        }
                    } catch {
                        MoQLogger.player.error("Video frame processing error: \(error)")
                        continuation.yield(.error(.video, error.localizedDescription))
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(.trackStopped(.video))
                }
            }
        }

        // Coordinator: wait for both tasks and emit allTracksStopped
        let vTask = videoTask
        let aTask = audioTask
        coordinatorTask = Task.detached {
            await vTask?.value
            await aTask?.value
            if !Task.isCancelled {
                continuation.yield(.allTracksStopped)
                continuation.finish()
            }
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
            if let vInfo = track as? MoQVideoTrackInfo {
                MoQLogger.player.debug(
                    "Video track: \(vInfo.name), codec=\(vInfo.config.codec), config=\(vInfo.config.debugDescription), container=\(vInfo.rawConfig.container)"
                )
                do {
                    videoSubscription = try MoQMediaTrack(
                        broadcast: vInfo.broadcast, name: vInfo.name,
                        container: vInfo.rawConfig.container,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.name): \(error)")
                }
            } else if let aInfo = track as? MoQAudioTrackInfo {
                MoQLogger.player.debug(
                    "Audio track: \(aInfo.name), config = \(aInfo.config.debugDescription), container=\(aInfo.rawConfig.container)"
                )
                do {
                    audioSubscription = try MoQMediaTrack(
                        broadcast: aInfo.broadcast, name: aInfo.name,
                        container: aInfo.rawConfig.container,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.name): \(error)")
                }
            }
        }
    }

}
