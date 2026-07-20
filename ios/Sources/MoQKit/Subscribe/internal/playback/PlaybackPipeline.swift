import AVFoundation
import Foundation
import MoqFFI

private let playbackStatsPTSCorrectionThreshold: Duration = .seconds(2)

enum PlaybackPipelineSwitchOutcome {
    case handled
    case restartRequired
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
@MainActor
final class PlaybackPipeline {
    // MARK: - Core dependencies

    private let mediaSource: BroadcastMediaSource
    private let tracker: PlaybackStatsTracker
    private let pipelineBus: PipelineBus

    // MARK: - Timing and diagnostics

    private var targetBuffering: Duration
    private let audioTimeline: TrackTimeline?
    private let timestampMapper: TimestampDomainMapper
    private let stallAttributor: PipelineStallAttributor
    private let frameObserver: any MediaFrameObserver
    private let playbackClock: any MediaPlaybackClock

    // MARK: - Renderers

    private let audioRenderer: AudioRenderer?
    private let videoRenderer: VideoRenderer?

    // MARK: - Track state

    private var videoTrackName: String?
    private var audioTrackName: String?
    private var videoEpoch: TrackEpoch = .zero
    private var audioEpoch: TrackEpoch = .zero

    // MARK: - Subscriptions and ingest tasks

    private var audioSubscription: MediaTrack?
    private var videoSubscription: MediaTrack?
    private var audioTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?
    private var pendingVideoCleanup: TrackIngestHandle?

    init(
        mediaSource: BroadcastMediaSource,
        videoTrack: VideoTrackInfo?,
        audioTrack: AudioTrackInfo?,
        targetBuffering: Duration,
        volume: Float,
        videoLayer: AVSampleBufferDisplayLayer,
        tracker: PlaybackStatsTracker,
        pipelineBus: PipelineBus
    ) throws {
        precondition(
            videoTrack != nil || audioTrack != nil,
            "PlaybackPipeline requires at least one track"
        )

        let frameObserver: any MediaFrameObserver = tracker
        let stallAttributor = PipelineStallAttributor(bus: pipelineBus)
        let latencyUs = Int64(clamping: targetBuffering.microsecondsUInt64Clamped)
        let audioTimeline = audioTrack == nil
            ? nil
            : TrackTimeline(policy: TimelinePolicy(targetLatencyUs: latencyUs))
        let initialVideoEpoch: TrackEpoch = videoTrack == nil ? .zero : TrackEpoch.zero.next()
        let initialAudioEpoch: TrackEpoch = audioTrack == nil ? .zero : TrackEpoch.zero.next()
        let subscriptions = try Self.makePlaybackSubscriptions(
            videoTrack: videoTrack,
            videoEpoch: initialVideoEpoch,
            audioTrack: audioTrack,
            audioEpoch: initialAudioEpoch,
            mediaSource: mediaSource,
            maxLatency: targetBuffering,
            tracker: tracker
        )

        self.mediaSource = mediaSource
        self.targetBuffering = targetBuffering
        self.tracker = tracker
        self.pipelineBus = pipelineBus
        self.frameObserver = frameObserver
        self.stallAttributor = stallAttributor
        self.audioTimeline = audioTimeline
        self.audioSubscription = subscriptions.audio
        self.videoSubscription = subscriptions.video
        self.videoTrackName = videoTrack?.name
        self.audioTrackName = audioTrack?.name
        self.videoEpoch = initialVideoEpoch
        self.audioEpoch = initialAudioEpoch

        let audioClock: AudioDrivenClock? = audioTrack != nil ? try AudioDrivenClock() : nil
        let playbackClock: any MediaPlaybackClock = audioClock ?? VideoDrivenClock()
        self.playbackClock = playbackClock

        if let audioTrack, let audioClock, let audioTimeline {
            let renderer = try AudioRenderer(
                config: audioTrack.rawConfig,
                clock: audioClock,
                timeline: audioTimeline,
                targetLatency: targetBuffering,
                initialVolume: volume,
                delegate: tracker,
                pipelineBus: pipelineBus,
                stallAttributor: stallAttributor
            )
            try renderer.start()
            self.audioRenderer = renderer
        } else {
            self.audioRenderer = nil
        }

        let rendererTrack: VideoRendererTrack?
        if let videoTrack {
            rendererTrack = try VideoRendererTrack(
                trackName: videoTrack.name,
                epoch: initialVideoEpoch,
                config: videoTrack.rawConfig,
                targetBuffering: targetBuffering
            )
        } else {
            rendererTrack = nil
        }

        let timestampMapper = TimestampDomainMapper(
            audioTimeline: audioTimeline,
            videoTimeline: rendererTrack?.timeline
        )
        self.timestampMapper = timestampMapper

        if let track = rendererTrack {
            let renderer = VideoRenderer(
                timing: playbackClock,
                timestampMapper: timestampMapper,
                track: track,
                layer: videoLayer,
                delegate: tracker,
                pipelineBus: pipelineBus,
                stallAttributor: stallAttributor
            )
            renderer.start()
            self.videoRenderer = renderer
        } else {
            self.videoRenderer = nil
        }

        if let audioRenderer = self.audioRenderer,
           let audioSub = subscriptions.audio,
           let audioTrack,
           let audioTimeline
        {
            self.audioTask = Self.makeAudioIngestTask(
                trackName: audioTrack.name,
                subscription: audioSub,
                renderer: audioRenderer,
                config: audioTrack.rawConfig,
                frameObserver: frameObserver,
                tracker: tracker,
                timeline: audioTimeline,
                pipelineBus: pipelineBus,
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
                pipelineBus: pipelineBus,
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
        let audioLiveTime: Int64? = hasAudio ? audioTimeline?.liveEdgeUs() : nil
        let videoLiveTime: Int64? = hasVideo ? videoLiveTimeForStats(hasAudio: hasAudio) : nil
        let targetUs = Int64(clamping: targetBuffering.microsecondsUInt64Clamped)

        if let audioTrackName, let audioRenderer {
            pipelineBus.emit(.latencySample(
                context: PipelineContextFactory(
                    trackId: audioTrackName,
                    mediaKind: .audio
                ).make(),
                currentUs: Self.latencyUs(
                    liveTime: audioLiveTime,
                    currentTimeUs: currentTimeUs
                ),
                targetUs: targetUs,
                bufferDepth: audioRenderer.diagnosticDepth
            ))
        }
        if let videoTrackName, let videoRenderer {
            pipelineBus.emit(.latencySample(
                context: PipelineContextFactory(
                    trackId: videoTrackName,
                    mediaKind: .video
                ).make(),
                currentUs: Self.latencyUs(
                    liveTime: videoLiveTime,
                    currentTimeUs: currentTimeUs
                ),
                targetUs: targetUs,
                bufferDepth: videoRenderer.activeDiagnosticDepth
            ))
        }

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
        audioTimeline?.setTargetLatencyUs(
            Int64(clamping: latency.microsecondsUInt64Clamped)
        )
        audioRenderer?.updateTargetLatency(latency)
        videoRenderer?.updateTargetBuffering(latency)
    }

    func switchVideo(
        to track: VideoTrackInfo,
        onAborted: @escaping @MainActor @Sendable (String?) -> Void
    ) throws -> PlaybackPipelineSwitchOutcome {
        guard let videoRenderer else { return .restartRequired }
        guard !videoRenderer.hasPendingTrack else { return .restartRequired }

        KitLogger.player.debug("Switching video track to \(track.name)")
        let nextEpoch = videoEpoch.next()
        tracker.emitSubscribeStart(kind: .video, trackName: track.name, trackEpoch: nextEpoch)
        let newSub: MediaTrack
        do {
            newSub = try mediaSource.subscribeMedia(
                MediaTrackRequest(track: track, targetBuffering: targetBuffering)
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
            "[Switch] Video track: \(track.name), codec=\(track.config.codec), config=\(track.config.debugDescription), container=\(track.rawConfig.container.moqKitDescription)"
        )

        let newRendererTrack = try VideoRendererTrack(
            trackName: track.name,
            epoch: nextEpoch,
            config: track.rawConfig,
            targetBuffering: targetBuffering
        )

        let oldHandle = TrackIngestHandle(task: videoTask, subscription: videoSubscription)
        let oldTrackName = videoTrackName
        let oldEpoch = videoEpoch
        videoEpoch = nextEpoch
        pendingVideoCleanup?.close()
        pendingVideoCleanup = oldHandle

        let trackerRef = self.tracker
        let switchedTrackName = track.name
        videoRenderer.setPendingTrack(
            newRendererTrack,
            onActivated: { [weak self] in
                oldHandle.close()
                trackerRef.emitTrackSwitch(
                    kind: .video, trackName: switchedTrackName, trackEpoch: nextEpoch
                )
                Task { @MainActor [weak self] in
                    guard let self, self.pendingVideoCleanup === oldHandle else { return }
                    self.pendingVideoCleanup = nil
                }
            },
            onAborted: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingVideoCleanup === oldHandle else { return }
                    self.videoTask?.cancel()
                    self.videoSubscription?.close()
                    let restored = oldHandle.take()
                    self.videoTask = restored.task
                    self.videoSubscription = restored.subscription
                    self.videoTrackName = oldTrackName
                    self.videoEpoch = oldEpoch
                    self.pendingVideoCleanup = nil
                    self.tracker.emitSubscribeError(
                        kind: .video,
                        trackName: switchedTrackName,
                        message: "Timed out waiting for a usable video keyframe",
                        trackEpoch: nextEpoch
                    )
                    onAborted(oldTrackName)
                    self.restartCoordinator()
                }
            }
        )

        videoSubscription = newSub
        videoTrackName = track.name
        videoTask = Self.makeVideoIngestTask(
            trackName: track.name,
            subscription: newSub,
            track: newRendererTrack,
            frameObserver: frameObserver,
            tracker: tracker,
            pipelineBus: pipelineBus,
            targetBuffering: targetBuffering,
            trackEpoch: nextEpoch
        )
        restartCoordinator()
        return .handled
    }

    func switchAudio(to track: AudioTrackInfo) throws -> PlaybackPipelineSwitchOutcome {
        guard let audioRenderer, let audioTimeline else { return .restartRequired }

        KitLogger.player.debug("Switching audio track to \(track.name)")

        let nextEpoch = audioEpoch.next()
        tracker.emitSubscribeStart(kind: .audio, trackName: track.name, trackEpoch: nextEpoch)
        let newSub: MediaTrack
        do {
            newSub = try mediaSource.subscribeMedia(
                MediaTrackRequest(track: track, targetBuffering: targetBuffering)
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
            timeline: audioTimeline,
            pipelineBus: pipelineBus,
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
        guard let videoTime = videoRenderer?.activeTimeline.liveEdgeUs(), videoTime >= 0
        else { return nil }
        guard hasAudio else { return videoTime }

        let mapped = timestampMapper.audioTimeUs(
            videoTimeUs: UInt64(videoTime),
            thresholdUs: Int64(clamping: playbackStatsPTSCorrectionThreshold.microsecondsUInt64Clamped)
        )
        guard mapped <= UInt64(Int64.max) else { return nil }
        return Int64(mapped)
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
        pipelineBus: PipelineBus,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) -> Task<Void, Never> {
        Task.detached {
            var firstAcceptedFrame = true
            let context = PipelineContextFactory(trackId: trackName, mediaKind: .video)
            frameObserver.onMediaTrackStarted(kind: .video)

            defer {
                KitLogger.player.debug("Exited video reading task track=\(trackName), cancelled=\(Task.isCancelled)")
            }

            do {
                for try await frame in subscription.frames {
                    if Task.isCancelled { break }
                    frameObserver.onMediaFrame(kind: .video, frame: frame)
                    let ptsUs = Int64(clamping: frame.timestampUs)
                    pipelineBus.emit(.frameArrived(
                        context: context.make(),
                        ptsUs: ptsUs,
                        groupSequence: nil,
                        frameIndex: nil,
                        bytes: frame.payload.count
                    ))

                    guard frame.timestampUs <= UInt64(Int64.max) else {
                        pipelineBus.emit(.frameDropped(
                            context: context.make(),
                            stage: .timeline,
                            reason: .invalidPayload,
                            bytes: UInt64(frame.payload.count)
                        ))
                        continue
                    }

                    let pipelineFrame = PipelineFrame(
                        payload: frame.payload,
                        timestampUs: ptsUs,
                        keyframe: frame.keyframe,
                        sizeBytes: frame.payload.count,
                        epoch: trackEpoch
                    )

                    switch track.timeline.onFrame(pipelineFrame) {
                    case .drop(_, let dropped):
                        pipelineBus.emit(.frameDropped(
                            context: context.make(),
                            stage: .timeline,
                            reason: .staleVsPlayback,
                            ptsUs: dropped.timestampUs,
                            count: 1,
                            bytes: UInt64(dropped.sizeBytes)
                        ))
                        continue
                    case .reset(let reason, let epoch, let resumeFrom, let gapUs):
                        let discarded = track.diagnosticDepth
                        track.flush()
                        pipelineBus.emit(.discontinuity(
                            context: context.make(),
                            epoch: epoch,
                            reason: reason == .publisherRewind ? .publisherRewind : .localReset
                        ))
                        if discarded.frames > 0 {
                            pipelineBus.emit(.frameDropped(
                                context: context.make(),
                                stage: .buffer,
                                reason: .resetFlush,
                                count: discarded.frames,
                                bytes: discarded.bytes
                            ))
                        }
                        if let gapUs {
                            frameObserver.onMediaDiscontinuity(kind: .video, gapUs: gapUs)
                        }
                        guard resumeFrom != nil else { continue }
                    case .admit:
                        break
                    }

                    let insertOutcome = track.insert(
                        payload: frame.payload,
                        timestampUs: frame.timestampUs,
                        keyframe: frame.keyframe
                    )

                    switch insertOutcome {
                    case .admitted(let depth, let evictions):
                        for eviction in evictions {
                            guard case .evictedGop(let count, let bytes) = eviction else {
                                continue
                            }
                            pipelineBus.emit(.frameDropped(
                                context: context.make(),
                                stage: .buffer,
                                reason: .backlogOverflow,
                                count: count,
                                bytes: bytes
                            ))
                        }
                        pipelineBus.emit(.frameAdmitted(
                            context: context.make(),
                            ptsUs: ptsUs,
                            bufferDepth: depth
                        ))
                        pipelineBus.emit(.bufferDepthChanged(
                            context: context.make(),
                            depth: depth
                        ))
                    case .rejected(let reason):
                        let dropReason: DropReason
                        switch reason {
                        case .waitingForKeyframe:
                            dropReason = .waitingForKeyframe
                        case .duplicate:
                            dropReason = .covered
                        case .oldEpoch, .unexpectedEpoch:
                            dropReason = .publisherRewind
                        case .frameTooLarge:
                            dropReason = .backlogOverflow
                        }
                        pipelineBus.emit(.frameDropped(
                            context: context.make(),
                            stage: .buffer,
                            reason: dropReason,
                            ptsUs: ptsUs,
                            count: 1,
                            bytes: UInt64(frame.payload.count)
                        ))
                    case .invalidPayload:
                        pipelineBus.emit(.frameDropped(
                            context: context.make(),
                            stage: .decoder,
                            reason: .invalidPayload,
                            ptsUs: ptsUs,
                            count: 1,
                            bytes: UInt64(frame.payload.count)
                        ))
                    }

                    if insertOutcome.accepted && firstAcceptedFrame {
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
                    pipelineBus.emit(.transportClosed(context: context.make(), error: nil))
                }
            } catch MoqError.Cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                KitLogger.player.error("Video track stream failed track=\(trackName): \(error)")
                tracker.emitSubscribeError(
                    kind: .video,
                    trackName: trackName,
                    message: error.localizedDescription,
                    trackEpoch: trackEpoch
                )
                pipelineBus.emit(.transportClosed(
                    context: context.make(),
                    error: PipelineError(
                        code: String(describing: type(of: error)),
                        message: error.localizedDescription
                    )
                ))
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
        timeline: TrackTimeline,
        pipelineBus: PipelineBus,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) -> Task<Void, Never> {
        Task.detached {
            frameObserver.onMediaTrackStarted(kind: .audio)
            let context = PipelineContextFactory(trackId: trackName, mediaKind: .audio)

            var decoder: AudioDecoder
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

            var firstFrame = true
            let recovery = AudioRecoveryController()

            defer {
                KitLogger.player.debug("Exited audio reading task track=\(trackName), cancelled=\(Task.isCancelled)")
            }

            do {
                for try await frame in subscription.frames {
                    if Task.isCancelled { break }
                    do {
                        frameObserver.onMediaFrame(kind: .audio, frame: frame)
                        let ptsUs = Int64(clamping: frame.timestampUs)
                        pipelineBus.emit(.frameArrived(
                            context: context.make(),
                            ptsUs: ptsUs,
                            groupSequence: nil,
                            frameIndex: nil,
                            bytes: frame.payload.count
                        ))

                        guard frame.timestampUs <= UInt64(Int64.max) else {
                            pipelineBus.emit(.frameDropped(
                                context: context.make(),
                                stage: .timeline,
                                reason: .invalidPayload,
                                bytes: UInt64(frame.payload.count)
                            ))
                            continue
                        }

                        let pipelineFrame = PipelineFrame(
                            payload: frame.payload,
                            timestampUs: ptsUs,
                            keyframe: frame.keyframe,
                            sizeBytes: frame.payload.count,
                            epoch: trackEpoch
                        )
                        switch timeline.onFrame(pipelineFrame) {
                        case .drop(_, let dropped):
                            pipelineBus.emit(.frameDropped(
                                context: context.make(),
                                stage: .timeline,
                                reason: .staleVsPlayback,
                                ptsUs: dropped.timestampUs,
                                bytes: UInt64(dropped.sizeBytes)
                            ))
                            continue
                        case .reset(let reason, let epoch, _, let gapUs):
                            renderer.flush()
                            pipelineBus.emit(.discontinuity(
                                context: context.make(),
                                epoch: epoch,
                                reason: reason == .publisherRewind ? .publisherRewind : .localReset
                            ))
                            if let gapUs {
                                frameObserver.onMediaDiscontinuity(kind: .audio, gapUs: gapUs)
                            }
                        case .admit:
                            break
                        }

                        pipelineBus.emit(.decoderInputQueued(
                            context: context.make(),
                            ptsUs: ptsUs
                        ))
                        let pcm = try decoder.decode(payload: frame.payload)
                        pipelineBus.emit(.decoderOutputReady(
                            context: context.make(),
                            ptsUs: ptsUs
                        ))
                        let write = renderer.enqueue(
                            pcm: pcm,
                            timestampUs: frame.timestampUs
                        )
                        let depth = renderer.diagnosticDepth
                        let decodedFrameSize = max(Int(pcm.frameLength), 1)
                        let droppedFrames =
                            (write.rejectedOldFrames + write.evictedFrames)
                            / decodedFrameSize
                        if droppedFrames > 0 {
                            pipelineBus.emit(.frameDropped(
                                context: context.make(),
                                stage: .buffer,
                                reason: write.evictedFrames > 0
                                    ? .backlogOverflow
                                    : .staleVsPlayback,
                                ptsUs: ptsUs,
                                count: droppedFrames
                            ))
                        }
                        if write.acceptedFrames > 0 {
                            pipelineBus.emit(.frameAdmitted(
                                context: context.make(),
                                ptsUs: ptsUs,
                                bufferDepth: depth
                            ))
                        }
                        pipelineBus.emit(.bufferDepthChanged(
                            context: context.make(),
                            depth: depth
                        ))

                        if firstFrame, write.acceptedFrames > 0 {
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
                        pipelineBus.emit(.frameDropped(
                            context: context.make(),
                            stage: .decoder,
                            reason: .invalidPayload,
                            ptsUs: Int64(clamping: frame.timestampUs),
                            bytes: UInt64(frame.payload.count)
                        ))
                        tracker.emitDecodeError(
                            kind: .audio,
                            trackName: trackName,
                            message: error.localizedDescription
                        )
                        let attempt = recovery.onFailure(
                            trigger: error.localizedDescription
                        )
                        pipelineBus.emit(.decoderRecovery(
                            context: context.make(),
                            attempt: attempt.attempt,
                            step: attempt.step,
                            trigger: attempt.trigger
                        ))
                        guard attempt.step == .rebuild else {
                            pipelineBus.emit(.transportClosed(
                                context: context.make(),
                                error: PipelineError(
                                    code: "audio-decoder-failed",
                                    message: error.localizedDescription
                                )
                            ))
                            return
                        }
                        do {
                            decoder = try AudioDecoder(config: config)
                            renderer.flush()
                            pipelineBus.emit(.decoderFlushed(
                                context: context.make(),
                                reason: .decoderRecovery,
                                trigger: attempt.trigger,
                                droppedFrames: 0
                            ))
                        } catch {
                            pipelineBus.emit(.transportClosed(
                                context: context.make(),
                                error: PipelineError(
                                    code: "audio-decoder-rebuild-failed",
                                    message: error.localizedDescription
                                )
                            ))
                            return
                        }
                    }
                }
                if !Task.isCancelled {
                    KitLogger.player.debug("Audio track stream ended track=\(trackName)")
                    tracker.emitSubscribeEnd(kind: .audio, trackName: trackName, trackEpoch: trackEpoch)
                    pipelineBus.emit(.transportClosed(context: context.make(), error: nil))
                }
            } catch MoqError.Cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                KitLogger.player.error("Audio track stream failed track=\(trackName): \(error)")
                tracker.emitSubscribeError(
                    kind: .audio,
                    trackName: trackName,
                    message: error.localizedDescription,
                    trackEpoch: trackEpoch
                )
                pipelineBus.emit(.transportClosed(
                    context: context.make(),
                    error: PipelineError(
                        code: String(describing: type(of: error)),
                        message: error.localizedDescription
                    )
                ))
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

}
