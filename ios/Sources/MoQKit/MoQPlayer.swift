import AVFoundation
import CoreMedia

// MARK: - LatencyInfo

public struct LatencyInfo: Sendable {
    public let audioMs: Double?
    public let videoMs: Double?
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

// MARK: - MoQAVPlayer

@MainActor
public final class MoQAVPlayer {
    public var videoLayer: AVSampleBufferDisplayLayer
    public let events: AsyncStream<MoQPlayerEvent>

    private let audioRenderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    private let tracks: [any MoQTrackInfo]
    private let maxLatencyMs: UInt64

    private var videoSubscription: MoQMediaTrack?
    private var audioSubscription: MoQMediaTrack?
    private var videoFormatDescription: CMFormatDescription?
    private var audioFormatDescription: CMFormatDescription?

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?

    private let eventsContinuation: AsyncStream<MoQPlayerEvent>.Continuation

    private var hasVideoTrack: Bool { tracks.contains(where: { $0 is MoQVideoTrackInfo }) }
    private var hasAudioTrack: Bool { tracks.contains(where: { $0 is MoQAudioTrackInfo }) }

    public init(
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
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            payload: frame.payload, timestampUs: frame.timestampUs,
                            formatDescription: vFmt
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
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            payload: frame.payload, timestampUs: frame.timestampUs,
                            formatDescription: aFmt
                        )
                        audioTracer.record(ptsUs: frame.timestampUs)
                        renderer.enqueue(sb)
                        if firstFrame {
                            firstFrame = false
                            continuation.yield(.trackPlaying(.audio))
                        }
                        if playbackStarted.setIfFirst() && shouldSync {
                            await MainActor.run {
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000)) }
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

        videoSubscription?.close()
        audioSubscription?.close()
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

        videoSubscription?.close()
        audioSubscription?.close()
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
                        "Failed to build video format for \(vInfo.name): \(error)"
                    )
                }
                do {
                    videoSubscription = try MoQMediaTrack(
                        broadcast: vInfo.broadcast, name: vInfo.name,
                        maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.name): \(error)"
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
                        "Failed to build audio format for \(aInfo.name): \(error)"
                    )
                }
                do {
                    audioSubscription = try MoQMediaTrack(
                        broadcast: aInfo.broadcast, name: aInfo.name,
                        maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.name): \(error)"
                    )
                }
            }
        }
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
