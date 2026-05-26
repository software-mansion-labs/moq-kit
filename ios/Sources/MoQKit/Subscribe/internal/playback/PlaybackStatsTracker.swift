import Foundation

struct PlaybackStartContext: Sendable {
    let kind: MediaFrameKind
    let trackName: String
    let sourceTimestampUs: UInt64
    let targetBuffering: Duration
    let trackEpoch: TrackEpoch
}

/// Owns playback statistics state and emits playback-lifecycle events at the same
/// call site that mutates state. The bulky counters and timing state live in focused
/// helpers; this type remains the facade used by Player, PlaybackPipeline, and renderers.
///
/// Thread safety: mutable helper state is guarded by `lock`, except for the audio
/// first-sample handoff, which uses its own gate so the render callback can keep a
/// non-locking pending-start probe.
final class PlaybackStatsTracker: MediaFrameObserver, @unchecked Sendable {
    private let lock = UnfairLock()
    private let wallClock: any PlaybackWallClock
    private let clock: ContinuousClock
    private let events: PlayerEventHub
    private let audioStartHandoff = AudioPlaybackStartHandoff()

    private var lifecycle = PlaybackLifecycleState()
    private var samples = PlaybackSampleStats()
    private var statsPublisher = PlaybackStatsPublisher()

    init(
        events: PlayerEventHub,
        clock: ContinuousClock = ContinuousClock(),
        wallClock: any PlaybackWallClock = HostPlaybackWallClock()
    ) {
        self.events = events
        self.clock = clock
        self.wallClock = wallClock
    }

    // MARK: - Session lifecycle

    /// Called from `Player.play()` together with `events.emit(.playbackRequest, ...)`.
    /// Records the request time used to derive TTFF, and resets per-session counters.
    func beginSession(rebufferKind: MediaFrameKind) {
        let instant = nowInstant()
        lock.withLock {
            lifecycle.beginSession(rebufferKind: rebufferKind, at: instant)
        }
        audioStartHandoff.clear()
    }

    /// Called on permanent teardown — fully resets state and notifies subscribers with
    /// an empty snapshot.
    func reset() {
        let listeners: [PlaybackStatsListener] = lock.withLock {
            lifecycle.reset()
            samples.reset()
            return statsPublisher.reset()
        }
        audioStartHandoff.clear()
        notify(listeners, stats: .empty)
    }

    /// Closes out any in-flight stall — used by Player when emitting playbackEnd /
    /// playerDestroy so rebufferingRatio doesn't accrue indefinitely.
    func closeOutInFlightStalls() {
        let instant = nowInstant()
        lock.withLock {
            lifecycle.closeOutInFlightStalls(at: instant)
        }
    }

    // MARK: - Track lifecycle (called by PlaybackPipeline)

    func emitSubscribeStart(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSubscribeStart(
                trackEvent(kind: kind, trackName: trackName, trackEpoch: trackEpoch)
            )
        )
        let instant = nowInstant()
        lock.withLock {
            lifecycle.recordSubscribeStart(
                kind: kind,
                trackName: trackName,
                trackEpoch: trackEpoch,
                at: instant
            )
        }
    }

    func emitSubscribeError(
        kind: MediaFrameKind,
        trackName: String,
        message: String,
        trackEpoch: TrackEpoch
    ) {
        events.emit(
            .trackSubscribeError(
                PlayerTrackErrorEvent(
                    track: trackEvent(kind: kind, trackName: trackName, trackEpoch: trackEpoch),
                    message: message
                )
            )
        )
        lock.withLock {
            lifecycle.recordSubscribeError(
                kind: kind,
                message: message,
                trackEpoch: trackEpoch
            )
        }
    }

    func emitSubscribeEnd(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSubscribeEnd(
                trackEvent(kind: kind, trackName: trackName, trackEpoch: trackEpoch)
            )
        )
    }

    /// Called by an ingest task on the first accepted/decoded frame. Emits `.trackReady`
    /// and updates TTFF / switch milestones.
    func emitTrackReady(
        kind: MediaFrameKind,
        trackName: String,
        trackEpoch: TrackEpoch,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        keyframe: Bool,
        payloadBytes: Int
    ) {
        events.emit(
            .trackReady(
                PlayerTrackReadyEvent(
                    track: trackEvent(kind: kind, trackName: trackName, trackEpoch: trackEpoch),
                    sourceTimestampUs: sourceTimestampUs,
                    targetBuffering: targetBuffering,
                    keyframe: keyframe,
                    payloadBytes: UInt64(max(0, payloadBytes))
                )
            )
        )
        let instant = nowInstant()
        lock.withLock {
            lifecycle.recordTrackReady(
                kind: kind,
                trackEpoch: trackEpoch,
                at: instant
            )
        }
    }

    /// Emits `.trackSwitch` — called by audio ingest on first frame after a switch
    /// and by the video renderer when it cuts over to the pending track.
    func emitTrackSwitch(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSwitch(
                trackEvent(kind: kind, trackName: trackName, trackEpoch: trackEpoch)
            )
        )
        let instant = nowInstant()
        lock.withLock {
            lifecycle.recordTrackSwitch(kind: kind, at: instant)
        }
    }

    func emitDecodeError(kind: MediaFrameKind, trackName: String, message: String) {
        events.emit(
            .decodeError(
                PlayerTrackErrorEvent(
                    track: trackEvent(kind: kind, trackName: trackName),
                    message: message
                )
            )
        )
    }

    /// Emits `.playbackEnd`. Player calls this on permanent teardown; the pipeline
    /// coordinator task calls this when all upstream tracks end naturally.
    func emitPlaybackEnd(reason: String? = nil) {
        events.emit(.playbackEnd(PlayerPlaybackEndEvent(reason: reason)))
    }

    /// Subscribe to all events.
    func subscribeEvents(
        _ listener: @escaping @MainActor @Sendable (PlayerEvent) -> Void
    ) -> PlayerEventSubscription {
        events.subscribe(listener)
    }

    // MARK: - Stalls

    func noteStall(kind: MediaFrameKind, stalled: Bool) {
        let instant = nowInstant()
        let change = lock.withLock {
            lifecycle.recordStall(kind: kind, stalled: stalled, at: instant)
        }

        guard let change else { return }
        let track = trackEvent(kind: change.kind)
        events.emit(change.stalled ? .trackStallStart(track) : .trackStallEnd(track))
        if change.rebufferChanged {
            events.emit(change.stalled ? .rebufferStart(track) : .rebufferEnd(track))
        }
    }

    // MARK: - First-frame playback handoff (audio)

    func armAudioPlaybackStart(_ context: PlaybackStartContext) {
        audioStartHandoff.prepare(context)
    }

    func armAudioPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        armAudioPlaybackStart(
            PlaybackStartContext(
                kind: .audio,
                trackName: trackName,
                sourceTimestampUs: sourceTimestampUs,
                targetBuffering: targetBuffering,
                trackEpoch: trackEpoch
            )
        )
    }

    func disarmAudioPlaybackStart() {
        audioStartHandoff.clear()
    }

    var isAudioPlaybackStartArmed: Bool {
        audioStartHandoff.hasPendingPlaybackStart
    }

    /// Called from the audio render-event bridge queue after `AudioRenderEventBridge`
    /// has lifted us off the realtime audio thread. Locks, listener fan-out, and event
    /// emission are safe here.
    func audioPlaybackStarted(
        timestampUs: UInt64,
        hostTime: UInt64?
    ) {
        guard let context = audioStartHandoff.consumeIfRendered(timestampUs: timestampUs)
        else { return }

        emitTrackPlaying(
            context: context,
            output: .audio(
                PlayerAudioPlaybackOutput(
                    timestampUs: timestampUs,
                    hostTime: hostTime
                )
            )
        )
    }

    /// Called from the video display-link observer on first visible frame.
    func videoPlaybackStarted(
        context: PlaybackStartContext,
        presentationTimeUs: UInt64,
        clockTimeUs: UInt64,
        buffer: Duration
    ) {
        emitTrackPlaying(
            context: context,
            output: .video(
                PlayerVideoPlaybackOutput(
                    presentationTimeUs: presentationTimeUs,
                    clockTimeUs: clockTimeUs,
                    buffer: buffer
                )
            )
        )
    }

    private func emitTrackPlaying(
        context: PlaybackStartContext,
        output: PlayerTrackPlaybackOutput
    ) {
        let event = PlayerTrackPlayingEvent(
            track: trackEvent(
                kind: context.kind,
                trackName: context.trackName,
                trackEpoch: context.trackEpoch
            ),
            sourceTimestampUs: context.sourceTimestampUs,
            targetBuffering: context.targetBuffering,
            output: output
        )
        events.emit(.trackPlaying(event))

        let instant = nowInstant()
        if context.trackEpoch == 1 {
            let shouldEmitPlaybackStart = lock.withLock {
                lifecycle.recordFirstPlay(context: context, at: instant)
            }
            if shouldEmitPlaybackStart {
                events.emit(.playbackStart(event))
            }
        } else {
            lock.withLock {
                lifecycle.recordSwitchPlaying(context: context, at: instant)
            }
        }
    }

    // MARK: - FPS / dropped frames

    func recordVideoFrameDisplayed() {
        lock.withLock {
            let now = nowNs()
            samples.recordVideoFrameDisplayed(now: now)
        }
    }

    func recordVideoFrameDropped() {
        lock.withLock {
            samples.recordVideoFrameDropped()
        }
    }

    func recordAudioFramesDropped(_ count: Int) {
        lock.withLock {
            samples.recordAudioFramesDropped(count)
        }
    }

    // MARK: - MediaFrameObserver

    func onMediaTrackStarted(kind: MediaFrameKind) {
        lock.withLock {
            samples.onMediaTrackStarted(kind: kind)
        }
    }

    func onMediaFrame(kind: MediaFrameKind, frame: MediaFrame) {
        lock.withLock {
            let now = nowNs()
            samples.onMediaFrame(kind: kind, frame: frame, now: now)
        }
    }

    func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        lock.withLock {
            samples.onMediaDiscontinuity(kind: kind, gapUs: gapUs)
        }
    }

    // MARK: - Stats

    /// Combines sampled latency/buffer values supplied by the pipeline with all
    /// tracker-owned counters into a single `PlaybackStats`.
    func getStats(
        audioLatency: Duration?,
        videoLatency: Duration?,
        audioRingBuffer: Duration?,
        videoJitterBuffer: Duration?
    ) -> PlaybackStats {
        lock.withLock {
            let instant = nowInstant()
            return makeStatsLocked(
                audioLatency: audioLatency,
                videoLatency: videoLatency,
                audioRingBuffer: audioRingBuffer,
                videoJitterBuffer: videoJitterBuffer,
                instant: instant
            )
        }
    }

    /// Called by `Player` on its 1 Hz sampling tick. Replaces the latest stats, recomputes
    /// the full snapshot, and pushes to all stats listeners.
    func publishStats(_ pipelineStats: PlaybackStats) {
        let update: (PlaybackStats, [PlaybackStatsListener]) = lock.withLock {
            let instant = nowInstant()
            let listeners = statsPublisher.publishStats(pipelineStats)
            let stats = makeStatsLocked(pipeline: pipelineStats, instant: instant)
            return (stats, listeners)
        }
        notify(update.1, stats: update.0)
    }

    func currentStats() -> PlaybackStats {
        lock.withLock {
            let instant = nowInstant()
            return makeStatsLocked(pipeline: statsPublisher.currentStats, instant: instant)
        }
    }

    func subscribeStats(
        _ listener: @escaping PlaybackStatsListener
    ) -> PlayerEventSubscription {
        let id = UUID()
        let initialStats = lock.withLock { () -> PlaybackStats? in
            let instant = nowInstant()
            guard let pipelineStats = statsPublisher.addListener(
                id: id,
                listener: listener
            ) else { return nil }

            return makeStatsLocked(pipeline: pipelineStats, instant: instant)
        }
        if let initialStats {
            Task { @MainActor in
                listener(initialStats)
            }
        }
        return PlayerEventSubscription { [weak self] in
            self?.lock.withLock {
                self?.statsPublisher.removeListener(id: id)
            }
        }
    }

    // MARK: - Stats assembly (called under lock)

    private func makeStatsLocked(
        pipeline: PlaybackStats,
        instant: ContinuousClock.Instant
    ) -> PlaybackStats {
        makeStatsLocked(
            audioLatency: pipeline.audioLatency,
            videoLatency: pipeline.videoLatency,
            audioRingBuffer: pipeline.audioRingBuffer,
            videoJitterBuffer: pipeline.videoJitterBuffer,
            instant: instant
        )
    }

    private func makeStatsLocked(
        audioLatency: Duration?,
        videoLatency: Duration?,
        audioRingBuffer: Duration?,
        videoJitterBuffer: Duration?,
        instant: ContinuousClock.Instant
    ) -> PlaybackStats {
        let now = nowNs()
        let lifecycleStats = lifecycle.snapshot(at: instant)
        let sampleStats = samples.snapshot(now: now)

        return PlaybackStats(
            audioLatency: audioLatency,
            videoLatency: videoLatency,
            audioStalls: lifecycleStats.audioStalls,
            videoStalls: lifecycleStats.videoStalls,
            audioBitrateKbps: sampleStats.audioBitrateKbps,
            videoBitrateKbps: sampleStats.videoBitrateKbps,
            timeToFirst: lifecycleStats.timeToFirst,
            videoFps: sampleStats.videoFps,
            audioFramesDropped: sampleStats.audioFramesDropped,
            videoFramesDropped: sampleStats.videoFramesDropped,
            audioRingBuffer: audioRingBuffer,
            videoJitterBuffer: videoJitterBuffer,
            audioArrival: sampleStats.audioArrival,
            videoArrival: sampleStats.videoArrival,
            audioSwitches: lifecycleStats.audioSwitches,
            videoSwitches: lifecycleStats.videoSwitches
        )
    }

    private func trackEvent(
        kind: MediaFrameKind,
        trackName: String? = nil,
        trackEpoch: TrackEpoch = .zero
    ) -> PlayerTrackEvent {
        PlayerTrackEvent(
            kind: kind.playerTrackKind,
            trackName: trackName,
            epoch: trackEpoch
        )
    }

    private func nowNs() -> UInt64 {
        UInt64(max(0, wallClock.now(in: .ns)))
    }

    private func nowInstant() -> ContinuousClock.Instant {
        clock.now
    }

    private func notify(
        _ listeners: [PlaybackStatsListener],
        stats: PlaybackStats
    ) {
        guard !listeners.isEmpty else { return }
        Task { @MainActor in
            for listener in listeners {
                listener(stats)
            }
        }
    }
}
