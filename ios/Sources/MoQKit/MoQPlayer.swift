import AVFoundation
import CoreMedia

enum MoQAVPlayerError: Error {
    case invalidTracksAmount(message: String)
}

// MARK: - MoQAVPlayer

@MainActor
public final class MoQAVPlayer {
    public var videoLayer: AVSampleBufferDisplayLayer
    public var onTrackEnded: (() -> Void)?
    public var onBufferingStateChanged: ((Bool) -> Void)?

    private let audioRenderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    private let videoSubscription: MoQVideoTrack?
    private let audioSubscription: MoQAudioTrack?
    private let videoFormatDescription: CMFormatDescription?
    private let audioFormatDescription: CMFormatDescription?

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    init(
        tracks: [any MoQTrackInfo],
        broadcastHandle: UInt32,
        maxLatencyMs: UInt64
    ) throws {

        var videoSub: MoQVideoTrack?
        var audioSub: MoQAudioTrack?
        var videoFmt: CMFormatDescription?
        var audioFmt: CMFormatDescription?

        if tracks.isEmpty || tracks.count > 2 {
            throw MoQAVPlayerError.invalidTracksAmount(message: "expected one or two tracks")
        }

        for track in tracks {
            if let vInfo = track as? MoQVideoTrackInfo {
                do {
                    videoFmt = try SampleBufferFactory.makeVideoFormatDescription(
                        from: vInfo.config)
                } catch {
                    MoQLogger.player.error(
                        "Failed to build video format for index \(vInfo.index): \(error)"
                    )
                }
                do {
                    videoSub = try MoQVideoTrack(
                        from: vInfo, broadcastHandle: broadcastHandle, maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to video track \(vInfo.index): \(error)"
                    )
                }
            } else if let aInfo = track as? MoQAudioTrackInfo {
                do {
                    audioFmt = try SampleBufferFactory.makeAudioFormatDescription(
                        from: aInfo.config)
                } catch {
                    MoQLogger.player.error(
                        "Failed to build audio format for index \(aInfo.index): \(error)"
                    )
                }
                do {
                    audioSub = try MoQAudioTrack(
                        from: aInfo, broadcastHandle: broadcastHandle, maxLatencyMs: maxLatencyMs)
                } catch {
                    MoQLogger.player.error(
                        "Failed to subscribe to audio track \(aInfo.index): \(error)"
                    )
                }
            }
        }

        self.videoSubscription = videoSub
        self.audioSubscription = audioSub
        self.videoFormatDescription = videoFmt
        self.audioFormatDescription = audioFmt

        let audioRenderer = AVSampleBufferAudioRenderer()
        let videoLayer = AVSampleBufferDisplayLayer()
        let synchronizer = AVSampleBufferRenderSynchronizer()

        if audioSub != nil && videoSub != nil {
            synchronizer.addRenderer(audioRenderer)
            videoLayer.controlTimebase = synchronizer.timebase
        }

        self.audioRenderer = audioRenderer
        self.videoLayer = videoLayer
        self.synchronizer = synchronizer
    }

    public func play() async throws {
        guard self.audioTask == nil && self.videoTask == nil else { return }

        let baseTimestamp = BaseTimestamp()
        let playbackStarted = PlaybackStartFlag()
        let layer = videoLayer
        let renderer = audioRenderer
        let sync = synchronizer

        let shouldSync = self.audioSubscription != nil && self.videoSubscription != nil
        
        MoQLogger.player.debug("Starting playback, audio = \(self.audioSubscription != nil), video = \(self.videoSubscription != nil)")

        if let vTrack = videoSubscription, let vFmt = videoFormatDescription {
            videoTask = Task.detached {
                for await frame in vTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: vFmt, baseTimestampUs: baseUs
                        )
                        layer.enqueue(sb)
                        if playbackStarted.setIfFirst() && shouldSync {
                            MoQLogger.player.debug("Syncing audio and video feeds")
                            await MainActor.run {
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                            }
                        }
                    } catch {
                        MoQLogger.player.error("Video frame processing error: \(error)")
                    }
                }
            }
        }

        if let aTrack = audioSubscription, let aFmt = audioFormatDescription {
            audioTask = Task.detached {
                for await frame in aTrack.frames {
                    if Task.isCancelled { break }
                    do {
                        let baseUs = baseTimestamp.resolve(frame.timestampUs)
                        let sb = try SampleBufferFactory.makeSampleBuffer(
                            from: frame, formatDescription: aFmt, baseTimestampUs: baseUs
                        )
                        renderer.enqueue(sb)
                        if playbackStarted.setIfFirst() && shouldSync {
                            await MainActor.run {
                                sync.setRate(1.0, time: CMTime(value: 0, timescale: 1_000_000))
                            }
                        }
                    } catch {
                        MoQLogger.player.error("Audio frame processing error: \(error)")
                    }
                }
            }
        }
    }

    public func stopAll() async {
        MoQLogger.player.debug("Stopping the player")
        videoTask?.cancel()
        audioTask?.cancel()
        videoTask = nil
        audioTask = nil

        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)

        await videoSubscription?.close()
        await audioSubscription?.close()
    }

    deinit {
        videoTask?.cancel()
        audioTask?.cancel()
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
