import AVFoundation
import Foundation
import MoQKitFFI

private let playbackStatsPTSCorrectionThreshold: Duration = .seconds(2)

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
    private var targetBuffering: Duration
    private let tracker: PlaybackStatsTracker
    private let aligner: MediaTimestampAligner
    private let frameObserver: any MediaFrameObserver
    private let playbackClock: any MediaPlaybackClock
    private let audioRenderer: AudioRenderer?
    private let videoRenderer: VideoRenderer?
    private var videoTrackName: String?
    private var audioTrackName: String?
    private var videoEpoch: TrackEpoch = .zero
    private var audioEpoch: TrackEpoch = .zero

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
        targetBuffering: Duration,
        volume: Float,
        videoLayer: AVSampleBufferDisplayLayer,
        tracker: PlaybackStatsTracker
    ) throws {
        precondition(
            videoTrack != nil || audioTrack != nil,
            "PlaybackPipeline requires at least one track"
        )

        let aligner = MediaTimestampAligner()
        let frameObserver = CompositeMediaFrameObserver([tracker, aligner])
        let initialVideoEpoch: TrackEpoch = videoTrack == nil ? .zero : TrackEpoch.zero.next()
        let initialAudioEpoch: TrackEpoch = audioTrack == nil ? .zero : TrackEpoch.zero.next()
        let subscriptions = try Self.makePlaybackSubscriptions(
            videoTrack: videoTrack,
            videoEpoch: initialVideoEpoch,
            audioTrack: audioTrack,
            audioEpoch: initialAudioEpoch,
            catalog: catalog,
            maxLatency: targetBuffering,
            tracker: tracker
        )

        self.catalog = catalog
        self.targetBuffering = targetBuffering
        self.tracker = tracker
        self.aligner = aligner
        self.frameObserver = frameObserver
        self.audioSubscription = subscriptions.audio
        self.videoSubscription = subscriptions.video
        self.videoTrackName = videoTrack?.name
        self.audioTrackName = audioTrack?.name
        self.videoEpoch = initialVideoEpoch
        self.audioEpoch = initialAudioEpoch

        let audioClock: AudioDrivenClock? = audioTrack != nil ? try AudioDrivenClock() : nil
        let playbackClock: any MediaPlaybackClock = audioClock ?? VideoDrivenClock()
        self.playbackClock = playbackClock

        if let audioTrack, let audioClock {
            let renderer = try AudioRenderer(
                config: audioTrack.rawConfig,
                clock: audioClock,
                targetLatency: targetBuffering,
                initialVolume: volume,
                tracker: tracker
            )
            try renderer.start()
            self.audioRenderer = renderer
        } else {
            self.audioRenderer = nil
        }

        let rendererTrack: VideoRendererTrack?
        if let videoTrack {
            let track = try VideoRendererTrack(
                trackName: videoTrack.name,
                epoch: initialVideoEpoch,
                config: videoTrack.rawConfig,
                targetBuffering: targetBuffering
            )
            let renderer = VideoRenderer(
                timing: playbackClock,
                timestampAligner: aligner,
                track: track,
                layer: videoLayer,
                tracker: tracker
            )
            renderer.start()
            self.videoRenderer = renderer
            rendererTrack = track
        } else {
            self.videoRenderer = nil
            rendererTrack = nil
        }

        if let audioRenderer = self.audioRenderer,
           let audioSub = subscriptions.audio,
           let audioTrack
        {
            self.audioTask = Self.makeAudioIngestTask(
                trackName: audioTrack.name,
                subscription: audioSub,
                renderer: audioRenderer,
                config: audioTrack.rawConfig,
                frameObserver: frameObserver,
                tracker: tracker,
                targetBuffering: targetBuffering,
                trackEpoch: initialAudioEpoch
            )
        }

        if let videoSub = subscriptions.video, let rendererTrack {
            self.videoTask = Self.makeVideoIngestTask(
                trackName: videoTrack?.name ?? "unknown",
                subscription: videoSub,
                track: rendererTrack,
                frameObserver: frameObserver,
                tracker: tracker,
                targetBuffering: targetBuffering,
                trackEpoch: initialVideoEpoch
            )
        }

        restartCoordinator()
    }

    // MARK: - Public API

    func getStats() -> PlaybackStats {
        let hasAudio = audioRenderer != nil
        let hasVideo = videoRenderer != nil
        let currentTimeUs = playbackClock.currentTimeUs
        let audioLiveTime: Int64? = hasAudio ? aligner.audioLiveEdge.estimatedLivePTS() : nil
        let videoLiveTime: Int64? = hasVideo ? videoLiveTimeForStats(hasAudio: hasAudio) : nil

        return tracker.getStats(
            audioLatency: Self.playbackLatency(
                liveTime: audioLiveTime, currentTimeUs: currentTimeUs),
            videoLatency: Self.playbackLatency(
                liveTime: videoLiveTime, currentTimeUs: currentTimeUs),
            audioRingBuffer: audioRenderer?.bufferFill,
            videoJitterBuffer: videoRenderer?.bufferFill
        )
    }

    func setVolume(_ volume: Float) {
        audioRenderer?.setVolume(volume)
    }

    func updateTargetLatency(_ latency: Duration) {
        targetBuffering = latency
        audioRenderer?.updateTargetLatency(latency)
        videoRenderer?.updateTargetBuffering(latency)
    }

    func switchVideo(to track: VideoTrackInfo) throws -> PlaybackPipelineSwitchOutcome {
        guard let videoRenderer else { return .restartRequired }
        guard !videoRenderer.hasPendingTrack else { return .restartRequired }

        KitLogger.player.debug("Switching video track to \(track.name)")
        let nextEpoch = videoEpoch.next()
        tracker.emitSubscribeStart(kind: .video, trackName: track.name, trackEpoch: nextEpoch)
        let newSub: MediaTrack
        do {
            newSub = try Self.makeMediaTrack(
                name: track.name,
                container: track.rawConfig.container,
                catalog: catalog,
                maxLatency: targetBuffering
            )
        } catch {
            tracker.emitSubscribeError(
                kind: .video,
                trackName: track.name,
                message: error.localizedDescription,
                trackEpoch: nextEpoch
            )
            throw error
        }

        KitLogger.player.debug(
            "[Switch] Video track: \(track.name), codec=\(track.config.codec), config=\(track.config.debugDescription), container=\(track.rawConfig.container)"
        )

        let newRendererTrack = try VideoRendererTrack(
            trackName: track.name,
            epoch: nextEpoch,
            config: track.rawConfig,
            targetBuffering: targetBuffering
        )
        videoEpoch = nextEpoch

        let oldHandle = TrackIngestHandle(task: videoTask, subscription: videoSubscription)
        pendingVideoCleanup?.close()
        pendingVideoCleanup = oldHandle

        // pendingVideoCleanup is mutated only from the main actor (switchVideo / stop);
        // marshal the clear back there to avoid a cross-thread mutation, and compare
        // by identity so a concurrent switchVideo that already replaced the slot wins.
        let clearCleanup = DispatchWorkItem { [weak self] in
            guard let self, self.pendingVideoCleanup === oldHandle else { return }
            self.pendingVideoCleanup = nil
        }
        let trackerRef = self.tracker
        let switchedTrackName = track.name
        videoRenderer.setPendingTrack(newRendererTrack) {
            oldHandle.close()
            DispatchQueue.main.async(execute: clearCleanup)
            trackerRef.emitTrackSwitch(
                kind: .video, trackName: switchedTrackName, trackEpoch: nextEpoch
            )
        }

        videoSubscription = newSub
        videoTrackName = track.name
        videoTask = Self.makeVideoIngestTask(
            trackName: track.name,
            subscription: newSub,
            track: newRendererTrack,
            frameObserver: frameObserver,
            tracker: tracker,
            targetBuffering: targetBuffering,
            trackEpoch: nextEpoch
        )
        restartCoordinator()
        return .handled
    }

    func switchAudio(to track: AudioTrackInfo) throws -> PlaybackPipelineSwitchOutcome {
        guard let audioRenderer else { return .restartRequired }

        KitLogger.player.debug("Switching audio track to \(track.name)")

        let nextEpoch = audioEpoch.next()
        tracker.emitSubscribeStart(kind: .audio, trackName: track.name, trackEpoch: nextEpoch)
        let newSub: MediaTrack
        do {
            newSub = try Self.makeMediaTrack(
                name: track.name,
                container: track.rawConfig.container,
                catalog: catalog,
                maxLatency: targetBuffering
            )
        } catch {
            tracker.emitSubscribeError(
                kind: .audio,
                trackName: track.name,
                message: error.localizedDescription,
                trackEpoch: nextEpoch
            )
            throw error
        }
        let oldTask = audioTask
        let oldSub = audioSubscription

        audioSubscription = newSub
        audioTrackName = track.name
        audioEpoch = nextEpoch
        audioTask = Self.makeAudioIngestTask(
            trackName: track.name,
            subscription: newSub,
            renderer: audioRenderer,
            config: track.rawConfig,
            frameObserver: frameObserver,
            tracker: tracker,
            targetBuffering: targetBuffering,
            trackEpoch: nextEpoch
        )

        oldTask?.cancel()
        oldSub?.close()
        restartCoordinator()
        return .handled
    }

    func stop(reason: String = "pipeline stop requested") {
        KitLogger.player.debug(
            "Stopping playback pipeline reason=\(reason), videoTrack=\(self.videoTrackName ?? "none"), audioTrack=\(self.audioTrackName ?? "none"), hasVideoTask=\(self.videoTask != nil), hasAudioTask=\(self.audioTask != nil), hasPendingVideoCleanup=\(self.pendingVideoCleanup != nil)"
        )
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
            videoTrackName: videoTrackName,
            audioTrackName: audioTrackName,
            videoTask: videoTask,
            audioTask: audioTask,
            tracker: tracker
        )
    }

    /// Stats helper: returns the video live-edge timestamp.
    /// In audio-bearing modes the value is mapped into the audio-clock domain so both
    /// latencies are comparable against `playbackClock.currentTimeUs`. In video-only mode the
    /// raw video edge is correct as-is (the clock IS the video timeline).
    private func videoLiveTimeForStats(hasAudio: Bool) -> Int64? {
        guard let videoTime = aligner.videoLiveEdge.estimatedLivePTS(), videoTime >= 0
        else { return nil }
        guard hasAudio else { return videoTime }

        let mapped = aligner.audioTime(
            videoTime: UInt64(videoTime),
            threshold: Int64(clamping: playbackStatsPTSCorrectionThreshold.microsecondsUInt64Clamped)
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
        videoEpoch: TrackEpoch,
        audioTrack: AudioTrackInfo?,
        audioEpoch: TrackEpoch,
        catalog: Catalog,
        maxLatency: Duration,
        tracker: PlaybackStatsTracker
    ) throws -> PlaybackSubscriptions {
        var subscriptions = PlaybackSubscriptions()
        // Capture the first error only; per-track failures are reported via
        // `.trackSubscribeError` events. We rethrow only when *every* requested track
        // failed to subscribe.
        var firstError: Error?

        if let videoTrack {
            tracker.emitSubscribeStart(
                kind: .video, trackName: videoTrack.name, trackEpoch: videoEpoch
            )
            KitLogger.player.debug(
                "Video track: \(videoTrack.name), codec=\(videoTrack.config.codec), config=\(videoTrack.config.debugDescription), container=\(videoTrack.rawConfig.container)"
            )
            do {
                subscriptions.video = try makeMediaTrack(
                    name: videoTrack.name,
                    container: videoTrack.rawConfig.container,
                    catalog: catalog,
                    maxLatency: maxLatency
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to video track \(videoTrack.name): \(error)")
                tracker.emitSubscribeError(
                    kind: .video,
                    trackName: videoTrack.name,
                    message: error.localizedDescription,
                    trackEpoch: videoEpoch
                )
            }
        }

        if let audioTrack {
            tracker.emitSubscribeStart(
                kind: .audio, trackName: audioTrack.name, trackEpoch: audioEpoch
            )
            KitLogger.player.debug(
                "Audio track: \(audioTrack.name), config = \(audioTrack.config.debugDescription), container=\(audioTrack.rawConfig.container)"
            )
            do {
                subscriptions.audio = try makeMediaTrack(
                    name: audioTrack.name,
                    container: audioTrack.rawConfig.container,
                    catalog: catalog,
                    maxLatency: maxLatency
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to audio track \(audioTrack.name): \(error)")
                tracker.emitSubscribeError(
                    kind: .audio,
                    trackName: audioTrack.name,
                    message: error.localizedDescription,
                    trackEpoch: audioEpoch
                )
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
        maxLatency: Duration
    ) throws -> MediaTrack {
        try MediaTrack(
            broadcast: catalog.broadcast,
            name: name,
            container: container,
            maxLatencyMs: maxLatency.millisecondsUInt64Clamped
        )
    }

    fileprivate static func playbackLatency(
        liveTime: Int64?, currentTimeUs: UInt64
    ) -> Duration? {
        guard let liveTime, currentTimeUs <= UInt64(Int64.max) else { return nil }
        let result = liveTime.subtractingReportingOverflow(Int64(currentTimeUs))
        guard !result.overflow else { return nil }
        return .microseconds(max(0, result.partialValue))
    }

}

// MARK: - Ingest tasks

extension PlaybackPipeline {
    fileprivate static func makeVideoIngestTask(
        trackName: String,
        subscription: MediaTrack,
        track: VideoRendererTrack,
        frameObserver: any MediaFrameObserver,
        tracker: PlaybackStatsTracker,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) -> Task<Void, Never> {
        Task.detached {
            var lastPtsUs: UInt64? = nil
            var firstAcceptedFrame = true
            frameObserver.onMediaTrackStarted(kind: .video)

            defer {
                KitLogger.player.debug("Exited video reading task track=\(trackName), cancelled=\(Task.isCancelled)")
            }

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                if let gap = discontinuityGapUs(frame: frame, lastPtsUs: lastPtsUs) {
                    KitLogger.player.debug("Video discontinuity detected (gap: \(gap)us)")
                    frameObserver.onMediaDiscontinuity(kind: .video, gapUs: gap)
                }
                lastPtsUs = frame.timestampUs

                frameObserver.onMediaFrame(kind: .video, frame: frame)

                let accepted = track.insert(
                    payload: frame.payload,
                    timestampUs: frame.timestampUs,
                    keyframe: frame.keyframe
                )

                if accepted && firstAcceptedFrame {
                    firstAcceptedFrame = false
                    KitLogger.player.debug(
                        "First video frame accepted track=\(trackName), timestampUs=\(frame.timestampUs), keyframe=\(frame.keyframe), bytes=\(frame.payload.count), trackEpoch=\(trackEpoch)"
                    )
                    tracker.emitTrackReady(
                        kind: .video,
                        trackName: trackName,
                        trackEpoch: trackEpoch,
                        sourceTimestampUs: frame.timestampUs,
                        targetBuffering: targetBuffering,
                        keyframe: frame.keyframe,
                        payloadBytes: frame.payload.count
                    )
                }
            }
            if !Task.isCancelled {
                KitLogger.player.debug("Video track stream ended track=\(trackName)")
                tracker.emitSubscribeEnd(kind: .video, trackName: trackName, trackEpoch: trackEpoch)
            }
        }
    }

    fileprivate static func makeAudioIngestTask(
        trackName: String,
        subscription: MediaTrack,
        renderer: AudioRenderer,
        config: MoqAudio,
        frameObserver: any MediaFrameObserver,
        tracker: PlaybackStatsTracker,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) -> Task<Void, Never> {
        Task.detached {
            frameObserver.onMediaTrackStarted(kind: .audio)

            let decoder: AudioDecoder
            do {
                decoder = try AudioDecoder(config: config)
            } catch {
                KitLogger.player.error("Failed to create AudioDecoder: \(error)")
                tracker.emitDecodeError(
                    kind: .audio,
                    trackName: trackName,
                    message: error.localizedDescription
                )
                return
            }

            var lastPtsUs: UInt64? = nil
            var firstFrame = true

            defer {
                KitLogger.player.debug("Exited audio reading task track=\(trackName), cancelled=\(Task.isCancelled)")
            }

            for await frame in subscription.frames {
                if Task.isCancelled { break }
                do {
                    if let gap = discontinuityGapUs(frame: frame, lastPtsUs: lastPtsUs) {
                        KitLogger.player.debug(
                            "Audio discontinuity detected (gap: \(gap)us), flushing")
                        renderer.flush()
                        frameObserver.onMediaDiscontinuity(kind: .audio, gapUs: gap)
                    }
                    lastPtsUs = frame.timestampUs

                    frameObserver.onMediaFrame(kind: .audio, frame: frame)

                    let pcm = try decoder.decode(payload: frame.payload)
                    renderer.enqueue(pcm: pcm, timestampUs: frame.timestampUs)

                    if firstFrame {
                        firstFrame = false
                        KitLogger.player.debug(
                            "First audio frame decoded track=\(trackName), timestampUs=\(frame.timestampUs), bytes=\(frame.payload.count), trackEpoch=\(trackEpoch)"
                        )
                        renderer.expectPlaybackStart(
                            trackName: trackName,
                            sourceTimestampUs: frame.timestampUs,
                            targetBuffering: targetBuffering,
                            trackEpoch: trackEpoch
                        )
                        tracker.emitTrackReady(
                            kind: .audio,
                            trackName: trackName,
                            trackEpoch: trackEpoch,
                            sourceTimestampUs: frame.timestampUs,
                            targetBuffering: targetBuffering,
                            keyframe: frame.keyframe,
                            payloadBytes: frame.payload.count
                        )
                        if trackEpoch > 1 {
                            tracker.emitTrackSwitch(
                                kind: .audio, trackName: trackName, trackEpoch: trackEpoch
                            )
                        }
                    }
                } catch {
                    KitLogger.player.error("Audio decode error: \(error)")
                    tracker.emitDecodeError(
                        kind: .audio,
                        trackName: trackName,
                        message: error.localizedDescription
                    )
                }
            }
            if !Task.isCancelled {
                KitLogger.player.debug("Audio track stream ended track=\(trackName)")
                tracker.emitSubscribeEnd(kind: .audio, trackName: trackName, trackEpoch: trackEpoch)
            }
        }
    }

    fileprivate static func makeCoordinatorTask(
        videoTrackName: String?,
        audioTrackName: String?,
        videoTask: Task<Void, Never>?,
        audioTask: Task<Void, Never>?,
        tracker: PlaybackStatsTracker
    ) -> Task<Void, Never> {
        Task.detached {
            await videoTask?.value
            await audioTask?.value
            guard !Task.isCancelled else { return }
            KitLogger.player.debug(
                "Playback coordinator observed all track tasks ended; videoTrack=\(videoTrackName ?? "none"), audioTrack=\(audioTrackName ?? "none")"
            )
            tracker.emitPlaybackEnd()
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
