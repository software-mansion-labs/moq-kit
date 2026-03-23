import AVFoundation
import CoreMedia

// MARK: - PlaybackStats

public struct PlaybackStats: Sendable {
    public let audioLatencyMs: Double?
    public let videoLatencyMs: Double?

    public let audioStalls: StallStats?
    public let videoStalls: StallStats?

    public let audioBitrateKbps: Double?
    public let videoBitrateKbps: Double?

    public let timeToFirstAudioFrameMs: Double?
    public let timeToFirstVideoFrameMs: Double?

    public let videoFps: Double?

    public let audioFramesDropped: UInt64?
    public let videoFramesDropped: UInt64?
}

public struct StallStats: Sendable {
    public let count: UInt64
    public let totalDurationMs: Double
    public let rebufferingRatio: Double
}

// MARK: - MoQPlayerEvent

public enum MoQPlayerEvent: Sendable {
    case trackPlaying(TrackKind)
    case trackPaused(TrackKind)
    case trackStopped(TrackKind)
    case allTracksStopped
    case error(TrackKind, String)

    public enum TrackKind: String, Sendable {
        case video, audio
    }
}

// MARK: - MoQPlayer

/// Adaptive real-time player for MoQ media playback.
@MainActor
public final class MoQPlayer {
    public let videoLayer: AVSampleBufferDisplayLayer
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

    public func updateTargetLatency(ms: UInt64) {
        targetBufferingMs = ms
        audioRenderer?.updateTargetLatency(ms: Int(ms))
        videoRenderer?.updateTargetBuffering(ms: ms)
    }

    public nonisolated var stats: PlaybackStats {
        accumulator.snapshot(
            audioLatencyMs: hasAudioTrack ? audioTracer?.latencyMs : nil,
            videoLatencyMs: hasVideoTrack ? videoTracer?.latencyMs : nil
        )
    }

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

    public func pause() async {
        teardown(permanent: false)

        if hasVideoTrack {
            eventsContinuation.yield(.trackPaused(.video))
        }
        if hasAudioTrack {
            eventsContinuation.yield(.trackPaused(.audio))
        }
    }

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
            accumulator.reset()

            try? AVAudioSession.sharedInstance().setActive(false)

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
            config: aInfo.config,
            timebase: timebase,
            targetLatencyMs: Int(targetBufferingMs),
            metrics: accumulator
        )
        try renderer.start()
        self.audioRenderer = renderer
    }

    private func setupVideoRenderer(timebase: CMTimebase) throws {
        guard let vInfo = tracks.compactMap({ $0 as? MoQVideoTrackInfo }).first else {
            return
        }

        let renderer = try VideoRenderer(
            config: vInfo.config,
            timebase: timebase,
            isTimebaseOwner: mode == .videoOnly,
            targetBufferingMs: targetBufferingMs,
            layer: videoLayer,
            metrics: accumulator
        )
        renderer.start()
        self.videoRenderer = renderer
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
                    "Video track: \(vInfo.name), codec=\(vInfo.config.codec), config=\(vInfo.config.debugDescription)"
                )
                do {
                    videoSubscription = try MoQMediaTrack(
                        broadcast: vInfo.broadcast, name: vInfo.name,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.name): \(error)")
                }
            } else if let aInfo = track as? MoQAudioTrackInfo {
                MoQLogger.player.debug(
                    "Audio track: \(aInfo.name), config = \(aInfo.config.debugDescription)")
                do {
                    audioSubscription = try MoQMediaTrack(
                        broadcast: aInfo.broadcast, name: aInfo.name,
                        maxLatencyMs: targetBufferingMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.name): \(error)")
                }
            }
        }
    }

}
