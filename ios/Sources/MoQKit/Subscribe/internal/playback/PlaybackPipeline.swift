import AVFoundation
import Foundation
import MoQKitFFI

private let playbackStatsPTSCorrectionThresholdUs: Int64 = 2_000_000

enum PlaybackPipelineSwitchOutcome {
    case handled
    case restartRequired
}

private struct PlaybackSubscriptions {
    var video: MediaTrack? = nil
    var audio: MediaTrack? = nil
}

/// Decodes and renders subscribed media tracks, and exposes seamless rendition switching.
///
/// One pipeline instance covers all combinations of selected tracks:
/// - `audio + video` — `AudioDrivenClock` is the master clock; the audio renderer drives it.
/// - `audio only`    — same `AudioDrivenClock`, no video renderer.
/// - `video only`    — `VideoDrivenClock` drives the timeline directly.
///
/// The mode is determined by which of `audioRenderer` / `videoRenderer` is non-nil.
/// Player resolves track selection up front, so the pipeline always has at least one half.
final class PlaybackPipeline {
    private let catalog: Catalog
    private var targetBufferingMs: UInt64
    private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
    private let stats: PlaybackStatsTracker
    private let aligner: MediaTimestampAligner
    private let frameObserver: any MediaFrameObserver
    private let clock: any MediaClock
    private let audioRenderer: AudioRenderer?
    private let videoRenderer: VideoRenderer?

    private var audioSubscription: MediaTrack?
    private var videoSubscription: MediaTrack?
    private var audioTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?
    private var pendingVideoCleanup: TrackIngestHandle?

    init(
        catalog: Catalog,
        videoTrack: VideoTrackInfo?,
        audioTrack: AudioTrackInfo?,
        targetBufferingMs: UInt64,
        volume: Float,
        videoLayer: AVSampleBufferDisplayLayer,
        eventContinuation: AsyncStream<PlayerEvent>.Continuation
    ) throws {
        precondition(
            videoTrack != nil || audioTrack != nil,
            "PlaybackPipeline requires at least one track"
        )

        let stats = PlaybackStatsTracker()
        let aligner = MediaTimestampAligner()
        let frameObserver = CompositeMediaFrameObserver([stats, aligner])
        let subscriptions = try Self.makePlaybackSubscriptions(
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            catalog: catalog,
            maxLatencyMs: targetBufferingMs,
            continuation: eventContinuation
        )

        self.catalog = catalog
        self.targetBufferingMs = targetBufferingMs
        self.eventContinuation = eventContinuation
        self.stats = stats
        self.aligner = aligner
        self.frameObserver = frameObserver
        self.audioSubscription = subscriptions.audio
        self.videoSubscription = subscriptions.video

        let audioClock: AudioDrivenClock? = audioTrack != nil ? try AudioDrivenClock() : nil
        let clock: any MediaClock = audioClock ?? VideoDrivenClock()
        self.clock = clock

        if let audioTrack, let audioClock {
            let renderer = try AudioRenderer(
                config: audioTrack.rawConfig,
                clock: audioClock,
                targetLatencyMs: Int(targetBufferingMs),
                initialVolume: volume,
                metrics: stats
            )
            try renderer.start()
            self.audioRenderer = renderer
        } else {
            self.audioRenderer = nil
        }

        let rendererTrack: VideoRendererTrack?
        if let videoTrack {
            let track = try VideoRendererTrack(
                config: videoTrack.rawConfig,
                targetBufferingMs: targetBufferingMs
            )
            let renderer = VideoRenderer(
                timing: clock,
                timestampAligner: aligner,
                track: track,
                layer: videoLayer,
                metrics: stats
            )
            renderer.start()
            self.videoRenderer = renderer
            rendererTrack = track
        } else {
            self.videoRenderer = nil
            rendererTrack = nil
        }

        stats.markPlayStart()

        if let audioRenderer = self.audioRenderer,
           let audioSub = subscriptions.audio,
           let audioTrack
        {
            self.audioTask = Self.makeAudioIngestTask(
                subscription: audioSub,
                renderer: audioRenderer,
                config: audioTrack.rawConfig,
                frameObserver: frameObserver,
                continuation: eventContinuation,
                isSwitch: false
            )
        }

        if let videoSub = subscriptions.video, let rendererTrack {
            self.videoTask = Self.makeVideoIngestTask(
                subscription: videoSub,
                track: rendererTrack,
                frameObserver: frameObserver,
                continuation: eventContinuation,
                isSwitch: false
            )
        }

        restartCoordinator()
    }

    // MARK: - Public API

    func getStats() -> PlaybackStats {
        let hasAudio = audioRenderer != nil
        let hasVideo = videoRenderer != nil
        let currentTimeUs = clock.currentTimeUs
        let audioLiveTime: Int64? = hasAudio ? aligner.audioLiveEdge.estimatedLivePTS() : nil
        let videoLiveTime: Int64? = hasVideo ? videoLiveTimeForStats(hasAudio: hasAudio) : nil

        return stats.getStats(
            audioLatencyMs: Self.playbackLatencyMs(
                liveTime: audioLiveTime, currentTimeUs: currentTimeUs),
            videoLatencyMs: Self.playbackLatencyMs(
                liveTime: videoLiveTime, currentTimeUs: currentTimeUs),
            audioRingBufferMs: audioRenderer?.bufferFillMs,
            videoJitterBufferMs: videoRenderer?.bufferFillMs
        )
    }

    func setVolume(_ volume: Float) {
        audioRenderer?.setVolume(volume)
    }

    func updateTargetLatency(ms: UInt64) {
        targetBufferingMs = ms
        audioRenderer?.updateTargetLatency(ms: Int(ms))
        videoRenderer?.updateTargetBuffering(ms: ms)
    }

    func switchVideo(to track: VideoTrackInfo) throws -> PlaybackPipelineSwitchOutcome {
        guard let videoRenderer else { return .restartRequired }
        guard !videoRenderer.hasPendingTrack else { return .restartRequired }

        KitLogger.player.debug("Switching video track to \(track.name)")
        let newSub = try Self.makeMediaTrack(
            name: track.name,
            container: track.rawConfig.container,
            catalog: catalog,
            maxLatencyMs: targetBufferingMs
        )

        KitLogger.player.debug(
            "[Switch] Video track: \(track.name), codec=\(track.config.codec), config=\(track.config.debugDescription), container=\(track.rawConfig.container)"
        )

        let newRendererTrack = try VideoRendererTrack(
            config: track.rawConfig,
            targetBufferingMs: targetBufferingMs
        )

        let oldHandle = TrackIngestHandle(task: videoTask, subscription: videoSubscription)
        pendingVideoCleanup?.close()
        pendingVideoCleanup = oldHandle

        let continuation = eventContinuation
        // pendingVideoCleanup is mutated only from the main actor (switchVideo / stop);
        // marshal the clear back there to avoid a cross-thread mutation, and compare
        // by identity so a concurrent switchVideo that already replaced the slot wins.
        let clearCleanup = DispatchWorkItem { [weak self] in
            guard let self, self.pendingVideoCleanup === oldHandle else { return }
            self.pendingVideoCleanup = nil
        }
        videoRenderer.setPendingTrack(newRendererTrack) {
            oldHandle.close()
            DispatchQueue.main.async(execute: clearCleanup)
            continuation.yield(.trackSwitched(.video))
        }

        videoSubscription = newSub
        videoTask = Self.makeVideoIngestTask(
            subscription: newSub,
            track: newRendererTrack,
            frameObserver: frameObserver,
            continuation: eventContinuation,
            isSwitch: true
        )
        restartCoordinator()
        return .handled
    }

    func switchAudio(to track: AudioTrackInfo) throws -> PlaybackPipelineSwitchOutcome {
        guard let audioRenderer else { return .restartRequired }

        KitLogger.player.debug("Switching audio track to \(track.name)")

        let newSub = try Self.makeMediaTrack(
            name: track.name,
            container: track.rawConfig.container,
            catalog: catalog,
            maxLatencyMs: targetBufferingMs
        )
        let oldTask = audioTask
        let oldSub = audioSubscription

        audioSubscription = newSub
        audioTask = Self.makeAudioIngestTask(
            subscription: newSub,
            renderer: audioRenderer,
            config: track.rawConfig,
            frameObserver: frameObserver,
            continuation: eventContinuation,
            isSwitch: true
        )

        oldTask?.cancel()
        oldSub?.close()
        restartCoordinator()
        return .handled
    }

    func stop() {
        coordinatorTask?.cancel()
        audioTask?.cancel()
        videoTask?.cancel()
        pendingVideoCleanup?.close()

        audioSubscription?.close()
        videoSubscription?.close()

        audioTask = nil
        videoTask = nil
        coordinatorTask = nil
        audioSubscription = nil
        videoSubscription = nil
        pendingVideoCleanup = nil

        audioRenderer?.stop()
        videoRenderer?.stop()
        // `stop()` halts ingest but leaves the last frame on screen; `flush()` clears it
        // so a subsequent pause→play cycle does not start with the stale image.
        videoRenderer?.flush()
    }

    // MARK: - Private

    private func restartCoordinator() {
        coordinatorTask?.cancel()
        coordinatorTask = Self.makeCoordinatorTask(
            videoTask: videoTask,
            audioTask: audioTask,
            continuation: eventContinuation
        )
    }

    /// Stats helper: returns the video live-edge timestamp.
    /// In audio-bearing modes the value is mapped into the audio-clock domain so both
    /// latencies are comparable against `clock.currentTimeUs`. In video-only mode the
    /// raw video edge is correct as-is (the clock IS the video timeline).
    private func videoLiveTimeForStats(hasAudio: Bool) -> Int64? {
        guard let videoTime = aligner.videoLiveEdge.estimatedLivePTS(), videoTime >= 0
        else { return nil }
        guard hasAudio else { return videoTime }

        let mapped = aligner.audioTime(
            videoTime: UInt64(videoTime),
            threshold: playbackStatsPTSCorrectionThresholdUs
        )
        guard mapped <= UInt64(Int64.max) else { return nil }
        return Int64(mapped)
    }
}

// MARK: - TrackIngestHandle

/// Holds a (task, subscription) pair so the previous video rendition can keep producing
/// frames until the renderer signals it has rendered a frame from the new rendition.
///
/// The video swap is double-buffered: we install a new ingest task immediately, but the
/// old task and its subscription must stay alive until the renderer's `onActivated` callback
/// fires. Closing the old pair early would tear down the jitter buffer that's still feeding
/// the display layer, producing a visible gap. The handle is captured by both the renderer
/// callback and the next switch's cleanup path; whichever runs first cancels the work,
/// the other becomes a no-op via the lock-protected nullification.
private final class TrackIngestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var subscription: MediaTrack?

    init(task: Task<Void, Never>?, subscription: MediaTrack?) {
        self.task = task
        self.subscription = subscription
    }

    func close() {
        lock.lock()
        let task = self.task
        let subscription = self.subscription
        self.task = nil
        self.subscription = nil
        lock.unlock()

        task?.cancel()
        subscription?.close()
    }
}

// MARK: - Subscription / stats helpers

extension PlaybackPipeline {
    fileprivate static func makePlaybackSubscriptions(
        videoTrack: VideoTrackInfo?,
        audioTrack: AudioTrackInfo?,
        catalog: Catalog,
        maxLatencyMs: UInt64,
        continuation: AsyncStream<PlayerEvent>.Continuation
    ) throws -> PlaybackSubscriptions {
        var subscriptions = PlaybackSubscriptions()
        // Capture the first error only; per-track failures are reported via .error events.
        // We rethrow only when *every* requested track failed to subscribe.
        var firstError: Error?

        if let videoTrack {
            KitLogger.player.debug(
                "Video track: \(videoTrack.name), codec=\(videoTrack.config.codec), config=\(videoTrack.config.debugDescription), container=\(videoTrack.rawConfig.container)"
            )
            do {
                subscriptions.video = try makeMediaTrack(
                    name: videoTrack.name,
                    container: videoTrack.rawConfig.container,
                    catalog: catalog,
                    maxLatencyMs: maxLatencyMs
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to video track \(videoTrack.name): \(error)")
                continuation.yield(.error(.video, error.localizedDescription))
            }
        }

        if let audioTrack {
            KitLogger.player.debug(
                "Audio track: \(audioTrack.name), config = \(audioTrack.config.debugDescription), container=\(audioTrack.rawConfig.container)"
            )
            do {
                subscriptions.audio = try makeMediaTrack(
                    name: audioTrack.name,
                    container: audioTrack.rawConfig.container,
                    catalog: catalog,
                    maxLatencyMs: maxLatencyMs
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to audio track \(audioTrack.name): \(error)")
                continuation.yield(.error(.audio, error.localizedDescription))
            }
        }

        if subscriptions.video == nil && subscriptions.audio == nil, let firstError {
            throw firstError
        }
        return subscriptions
    }

    fileprivate static func makeMediaTrack(
        name: String,
        container: Container,
        catalog: Catalog,
        maxLatencyMs: UInt64
    ) throws -> MediaTrack {
        try MediaTrack(
            broadcast: catalog.broadcast,
            name: name,
            container: container,
            maxLatencyMs: maxLatencyMs
        )
    }

    fileprivate static func playbackLatencyMs(
        liveTime: Int64?, currentTimeUs: UInt64
    ) -> Double? {
        guard let liveTime, currentTimeUs <= UInt64(Int64.max) else { return nil }
        let result = liveTime.subtractingReportingOverflow(Int64(currentTimeUs))
        guard !result.overflow else { return nil }
        return Double(max(0, result.partialValue)) / 1_000.0
    }
}

// MARK: - Ingest tasks

extension PlaybackPipeline {
    fileprivate static func makeVideoIngestTask(
        subscription: MediaTrack,
        track: VideoRendererTrack,
        frameObserver: any MediaFrameObserver,
        continuation: AsyncStream<PlayerEvent>.Continuation,
        isSwitch: Bool
    ) -> Task<Void, Never> {
        Task.detached {
            var lastPtsUs: UInt64? = nil
            var firstFrame = true

            defer {
                KitLogger.player.debug("Exited video reading task")
            }

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                if let gap = discontinuityGapUs(frame: frame, lastPtsUs: lastPtsUs) {
                    KitLogger.player.debug("Video discontinuity detected (gap: \(gap)us)")
                    frameObserver.onFrameDiscontinuity(kind: .video, gapUs: gap)
                }
                lastPtsUs = frame.timestampUs

                frameObserver.onMediaFrame(frame, kind: .video)

                track.insert(
                    payload: frame.payload,
                    timestampUs: frame.timestampUs,
                    keyframe: frame.keyframe
                )

                if firstFrame {
                    firstFrame = false
                    if !isSwitch {
                        continuation.yield(.trackPlaying(.video))
                    }
                }
            }
            if !Task.isCancelled {
                continuation.yield(.trackStopped(.video))
            }
        }
    }

    fileprivate static func makeAudioIngestTask(
        subscription: MediaTrack,
        renderer: AudioRenderer,
        config: MoqAudio,
        frameObserver: any MediaFrameObserver,
        continuation: AsyncStream<PlayerEvent>.Continuation,
        isSwitch: Bool
    ) -> Task<Void, Never> {
        Task.detached {
            let decoder: AudioDecoder
            do {
                decoder = try AudioDecoder(config: config)
            } catch {
                KitLogger.player.error("Failed to create AudioDecoder: \(error)")
                continuation.yield(.error(.audio, error.localizedDescription))
                return
            }

            var lastPtsUs: UInt64? = nil
            var firstFrame = true

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                do {
                    if let gap = discontinuityGapUs(frame: frame, lastPtsUs: lastPtsUs) {
                        KitLogger.player.debug(
                            "Audio discontinuity detected (gap: \(gap)us), flushing")
                        renderer.flush()
                        frameObserver.onFrameDiscontinuity(kind: .audio, gapUs: gap)
                    }
                    lastPtsUs = frame.timestampUs

                    frameObserver.onMediaFrame(frame, kind: .audio)

                    let pcm = try decoder.decode(payload: frame.payload)
                    renderer.enqueue(pcm: pcm, timestampUs: frame.timestampUs)

                    if firstFrame {
                        firstFrame = false
                        let event: PlayerEvent =
                            isSwitch ? .trackSwitched(.audio) : .trackPlaying(.audio)
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

    fileprivate static func makeCoordinatorTask(
        videoTask: Task<Void, Never>?,
        audioTask: Task<Void, Never>?,
        continuation: AsyncStream<PlayerEvent>.Continuation
    ) -> Task<Void, Never> {
        Task.detached {
            await videoTask?.value
            await audioTask?.value
            guard !Task.isCancelled else { return }
            continuation.yield(.allTracksStopped)
            continuation.finish()
        }
    }

    /// Detects a PTS discontinuity: keyframe with >500ms jump from the last seen timestamp.
    /// Returns the gap in microseconds when one is detected, or `nil`.
    fileprivate static func discontinuityGapUs(
        frame: MediaFrame, lastPtsUs: UInt64?
    ) -> UInt64? {
        guard frame.keyframe, let lastPtsUs else { return nil }
        let gap = frame.timestampUs > lastPtsUs
            ? frame.timestampUs - lastPtsUs
            : lastPtsUs - frame.timestampUs
        return gap > 500_000 ? gap : nil
    }
}
