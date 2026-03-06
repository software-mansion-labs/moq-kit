import AVFoundation
import CoreMedia

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

// MARK: - MoQAVPlayer

@MainActor
public final class MoQAVPlayer {
    public var videoLayer: AVSampleBufferDisplayLayer
    public let events: AsyncStream<MoQPlayerEvent>

    private let audioRenderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    private let tracks: [any MoQTrackInfo]
    private let maxLatencyMs: UInt64

    private var videoSubscription: MoQVideoTrack?
    private var audioSubscription: MoQAudioTrack?
    private var videoFormatDescription: CMFormatDescription?
    private var audioFormatDescription: CMFormatDescription?

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?

    private let eventsContinuation: AsyncStream<MoQPlayerEvent>.Continuation

    private var hasVideoTrack: Bool { tracks.contains(where: { $0 is MoQVideoTrackInfo }) }
    private var hasAudioTrack: Bool { tracks.contains(where: { $0 is MoQAudioTrackInfo }) }

    init(
        tracks: [any MoQTrackInfo],
        maxLatencyMs: UInt64
    ) throws {
        if tracks.isEmpty || tracks.count > 2 {
            throw MoQSessionError.invalidConfiguration("expected one or two tracks")
        }

        self.tracks = tracks
        self.maxLatencyMs = maxLatencyMs

        self.audioRenderer = AVSampleBufferAudioRenderer()
        self.videoLayer = AVSampleBufferDisplayLayer()
        self.synchronizer = AVSampleBufferRenderSynchronizer()

        var cont: AsyncStream<MoQPlayerEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
    }

    // MARK: - Public API

    public func play() async throws {
        guard videoTask == nil && audioTask == nil else { return }

        try subscribe()

        let shouldSync = audioSubscription != nil && videoSubscription != nil
        if shouldSync {
            MoQLogger.player.debug("Adding A/V synchronization")
            synchronizer.addRenderer(audioRenderer)
            videoLayer.controlTimebase = synchronizer.timebase
        }

        let baseTimestamp = BaseTimestamp()
        let playbackStarted = PlaybackStartFlag()
        let layer = videoLayer
        let renderer = audioRenderer
        let sync = synchronizer
        let continuation = eventsContinuation

        MoQLogger.player.debug(
            "Starting playback, audio = \(self.audioSubscription != nil), video = \(self.videoSubscription != nil)"
        )

        if let vTrack = videoSubscription, let vFmt = videoFormatDescription {
            let videoTracer = PacketTimingTracer(kind: .video, reportCallback: { report in
                MoQLogger.player.debug("\(report)")
            })

            videoTask = Task.detached {
                var firstFrame = true
                for await frame in vTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: vFmt, baseTimestampUs: baseUs
                        )
                        videoTracer.record(ptsUs: frame.timestampUs)
                        if !layer.isReadyForMoreMediaData {
                            MoQLogger.player.error(
                                "Trying to enqueue data for display layer that is already full")
                        }
                        layer.enqueue(sb)
                        if firstFrame {
                            firstFrame = false
                            continuation.yield(.trackPlaying(.video))
                        }
                        if playbackStarted.setIfFirst() && shouldSync {
                            MoQLogger.player.debug("Syncing audio and video feeds")
                            await MainActor.run {
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                            }
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

        if let aTrack = audioSubscription, let aFmt = audioFormatDescription {
            let audioTracer = PacketTimingTracer(kind: .audio, reportCallback: { report in
                MoQLogger.player.debug("\(report)")
            })

            audioTask = Task.detached {
                var firstFrame = true
                for await frame in aTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: aFmt, baseTimestampUs: baseUs
                        )
                        audioTracer.record(ptsUs: frame.timestampUs)
                        renderer.enqueue(sb)
                        if firstFrame {
                            firstFrame = false
                            continuation.yield(.trackPlaying(.audio))
                        }
                        if playbackStarted.setIfFirst() && shouldSync {
                            await MainActor.run {
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                            }
                        }
                    } catch {
                        MoQLogger.player.error("Audio frame processing error: \(error)")
                        continuation.yield(.error(.audio, error.localizedDescription))
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(.trackStopped(.audio))
                }
            }
        }

        // Coordinator: wait for both tasks and emit allTracksStopped if they ended naturally
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

    public func pause() async {
        videoTask?.cancel()
        audioTask?.cancel()
        coordinatorTask?.cancel()
        videoTask = nil
        audioTask = nil
        coordinatorTask = nil

        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        await synchronizer.removeRenderer(audioRenderer, at: .zero)
        videoLayer.controlTimebase = nil
        synchronizer.setRate(0, time: .zero)

        await videoSubscription?.close()
        await audioSubscription?.close()
        videoSubscription = nil
        audioSubscription = nil

        if hasVideoTrack {
            eventsContinuation.yield(.trackPaused(.video))
        }
        if hasAudioTrack {
            eventsContinuation.yield(.trackPaused(.audio))
        }
    }

    public func stopAll() async {
        MoQLogger.player.debug("Stopping the player")
        videoTask?.cancel()
        audioTask?.cancel()
        coordinatorTask?.cancel()
        videoTask = nil
        audioTask = nil
        coordinatorTask = nil

        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)

        await videoSubscription?.close()
        await audioSubscription?.close()
        videoSubscription = nil
        audioSubscription = nil

        eventsContinuation.finish()
    }

    deinit {
        videoTask?.cancel()
        audioTask?.cancel()
        coordinatorTask?.cancel()
        eventsContinuation.finish()
    }

    // MARK: - Private

    private func subscribe() throws {
        for track in tracks {
            if let vInfo = track as? MoQVideoTrackInfo {
                MoQLogger.player.debug(
                    "Video track information, name = \(vInfo.name), config = \(vInfo.config.debugDescription)"
                )

                do {
                    videoFormatDescription = try SampleBufferFactory.makeVideoFormatDescription(
                        from: vInfo.config)
                } catch {
                    MoQLogger.player.error(
                        "Failed to build video format for index \(vInfo.index): \(error)"
                    )
                }
                do {
                    videoSubscription = try MoQVideoTrack(
                        from: vInfo, maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.index): \(error)"
                    )
                }
            } else if let aInfo = track as? MoQAudioTrackInfo {
                MoQLogger.player.debug(
                    "Audio track information, name = \(aInfo.name), config = \(aInfo.config.debugDescription)"
                )

                do {
                    audioFormatDescription = try SampleBufferFactory.makeAudioFormatDescription(
                        from: aInfo.config)
                } catch {
                    MoQLogger.player.error(
                        "Failed to build audio format for index \(aInfo.index): \(error)"
                    )
                }
                do {
                    audioSubscription = try MoQAudioTrack(
                        from: aInfo, maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.index): \(error)"
                    )
                }
            }
        }
    }
}

// MARK: - PacketTimingTracer

/// Tracks wall-clock intervals between packet enqueues, comparing against PTS intervals
/// to detect stalls, bursts, and out-of-order timestamps.
private final class PacketTimingTracer: @unchecked Sendable {
    enum TrackKind: String { case video, audio }

    private let kind: TrackKind
    private let stallFactor: Double
    private let burstFactor: Double
    private let reportInterval: Int
    private let reportCallback: (String) -> Void
    private let lock = NSLock()

    // Per-packet state
    private var lastWallNs: UInt64?
    private var lastPtsUs: UInt64?
    private var highestPtsUs: UInt64?

    // Rolling window stats (reset each report)
    private var packetCount: Int = 0
    private var wallIntervalSumMs: Double = 0
    private var ptsIntervalSumMs: Double = 0
    private var intervalCount: Int = 0
    private var stallCount: Int = 0
    private var burstCount: Int = 0
    private var outOfOrderCount: Int = 0
    private var maxGapMs: Double = 0
    private var minGapMs: Double = .greatestFiniteMagnitude
    private var maxOooDeltaMs: Double = 0

    init(
        kind: TrackKind,
        stallFactor: Double = 2.0,
        burstFactor: Double = 0.3,
        reportInterval: Int = 120,
        reportCallback: @escaping(String) -> Void

    ) {
        self.kind = kind
        self.stallFactor = stallFactor
        self.burstFactor = burstFactor
        self.reportInterval = reportInterval
        self.reportCallback = reportCallback
    }

    func record(ptsUs: UInt64) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()

        // Out-of-order detection (compare against highest PTS seen, not just previous)
        if let highest = highestPtsUs, ptsUs < highest {
            outOfOrderCount += 1
            let deltaMs = Double(highest - ptsUs) / 1000.0
            maxOooDeltaMs = max(maxOooDeltaMs, deltaMs)
        }
        highestPtsUs = max(highestPtsUs ?? 0, ptsUs)

        // Interval classification
        if let prevWallNs = lastWallNs, let prevPtsUs = lastPtsUs {
            let wallDeltaMs = Double(nowNs - prevWallNs) / 1_000_000.0
            let isOoo = ptsUs < prevPtsUs

            if isOoo {
                MoQLogger.player.debug(
                    "[\(self.kind.rawValue)] Detected out-of-order packets, diff = \(prevPtsUs - ptsUs)"
                )
            }

            let ptsDeltaMs = isOoo ? 0.0 : Double(ptsUs - prevPtsUs) / 1000.0
            let isDiscontinuity = ptsDeltaMs > 2000.0

            // Skip classification for OOO or PTS discontinuities (>2s jump)
            if !isOoo && !isDiscontinuity {
                wallIntervalSumMs += wallDeltaMs
                ptsIntervalSumMs += ptsDeltaMs
                intervalCount += 1
                maxGapMs = max(maxGapMs, wallDeltaMs)
                minGapMs = min(minGapMs, wallDeltaMs)

                if ptsDeltaMs > 0 {
                    if wallDeltaMs > ptsDeltaMs * stallFactor {
                        stallCount += 1
                    } else if wallDeltaMs < ptsDeltaMs * burstFactor {
                        burstCount += 1
                    }
                }
            }
        }

        lastWallNs = nowNs
        lastPtsUs = ptsUs
        packetCount += 1

        let shouldReport = packetCount >= reportInterval
        let snapshot: (Int, Double, Double, Int, Int, Int, Double, Double, Double)?
        if shouldReport {
            let minG = minGapMs == .greatestFiniteMagnitude ? 0.0 : minGapMs
            snapshot = (
                packetCount,
                intervalCount > 0 ? wallIntervalSumMs / Double(intervalCount) : 0,
                intervalCount > 0 ? ptsIntervalSumMs / Double(intervalCount) : 0,
                stallCount, burstCount, outOfOrderCount,
                maxOooDeltaMs, minG, maxGapMs
            )
            packetCount = 0
            wallIntervalSumMs = 0
            ptsIntervalSumMs = 0
            intervalCount = 0
            stallCount = 0
            burstCount = 0
            outOfOrderCount = 0
            maxOooDeltaMs = 0
            maxGapMs = 0
            minGapMs = .greatestFiniteMagnitude
        } else {
            snapshot = nil
        }

        lock.unlock()

        if let (pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG) = snapshot {
            let msg = String(
                format:
                    "[%@] %d pkts | avg wall %.1fms avg pts %.1fms | stalls: %d bursts: %d | ooo: %d (max -%.1fms) | gap [%.1f, %.1f]ms",
                kind.rawValue, pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG
            )
            self.reportCallback(msg)
        }
    }
}

// MARK: - BaseTimestamp

/// Thread-safe container for the first frame timestamp, shared between video and audio tasks.
private final class BaseTimestamp: @unchecked Sendable {
    private var value: UInt64?
    private let lock = NSLock()

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

    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }
}
