import Foundation

struct PlaybackStartContext: Sendable {
    let kind: MediaFrameKind
    let trackName: String
    let sourceTimestampUs: UInt64
    let targetBuffering: Duration
    let trackEpoch: TrackEpoch
}

/// Owns all playback statistics state and emits playback-lifecycle events at the same
/// call site that mutates state. Replaces the prior split between a reporter, a sample
/// tracker, and an event-derived store: there is now one source of truth for stalls,
/// switches, TTFF, and per-kind samples, all directly driven by the renderers and ingest
/// tasks instead of being reconstructed from string-keyed event attributes.
///
/// Thread safety: all mutable state is guarded by `lock`. Renderers, ingest tasks, and
/// the audio render callback may call into the tracker concurrently. The audio render
/// callback uses a non-locking probe (`hasPendingAudioStart`) so it pays the lock cost
/// only while a first-sample handoff is actually pending.
final class PlaybackStatsTracker: MediaFrameObserver, @unchecked Sendable {
    // MARK: - Internal state shapes

    private struct TrackStallState: Sendable {
        var readyAt: ContinuousClock.Instant?
        var activeAt: ContinuousClock.Instant?
        var count: UInt64 = 0
        var duration: Duration = .zero
        var active: Bool = false

        mutating func markReady(at instant: ContinuousClock.Instant) {
            if readyAt == nil {
                readyAt = instant
            }
        }

        mutating func start(at instant: ContinuousClock.Instant) {
            markReady(at: instant)
            guard activeAt == nil else { return }
            activeAt = instant
            count += 1
        }

        mutating func end(at instant: ContinuousClock.Instant) {
            guard let startedAt = activeAt else { return }
            duration += startedAt.duration(to: instant)
            activeAt = nil
        }

        func stats(at instant: ContinuousClock.Instant) -> StallStats? {
            guard let readyAt else { return nil }

            var total = duration
            if let activeAt {
                total += activeAt.duration(to: instant)
            }
            let elapsed = readyAt.duration(to: instant)
            let elapsedMs = elapsed.milliseconds
            let totalMs = total.milliseconds
            let ratio = elapsedMs > 0 ? totalMs / elapsedMs : 0
            return StallStats(
                count: count,
                totalDuration: total,
                rebufferingRatio: ratio
            )
        }
    }

    private struct TrackSwitchState: Sendable {
        private struct Attempt: Sendable {
            var trackName: String?
            var startedAt: ContinuousClock.Instant
            var readyAt: ContinuousClock.Instant?
            var playingAt: ContinuousClock.Instant?
            var activeAt: ContinuousClock.Instant?
            var errorMessage: String?
        }

        private var latestAttempt: Attempt?
        private var didCountLatestCompletion = false
        var requestedCount: UInt64 = 0
        var completedCount: UInt64 = 0

        mutating func start(trackName: String?, at instant: ContinuousClock.Instant) {
            requestedCount += 1
            latestAttempt = Attempt(
                trackName: trackName,
                startedAt: instant
            )
            didCountLatestCompletion = false
        }

        mutating func markReady(at instant: ContinuousClock.Instant) {
            update { attempt in
                attempt.readyAt = attempt.readyAt ?? instant
            }
        }

        mutating func markPlaying(at instant: ContinuousClock.Instant) {
            update { attempt in
                attempt.playingAt = attempt.playingAt ?? instant
            }
        }

        mutating func markActive(at instant: ContinuousClock.Instant) {
            update { attempt in
                attempt.activeAt = attempt.activeAt ?? instant
            }
            guard latestAttempt?.activeAt != nil, !didCountLatestCompletion else { return }
            didCountLatestCompletion = true
            completedCount += 1
        }

        mutating func markError(_ message: String?) {
            update { attempt in
                attempt.errorMessage = message
            }
        }

        func stats() -> TrackSwitchStats? {
            guard requestedCount > 0 else { return nil }
            let latest = latestAttempt.map { attempt in
                TrackSwitch(
                    trackName: attempt.trackName,
                    isCompleted: attempt.activeAt != nil,
                    errorMessage: attempt.errorMessage,
                    switchToReady: elapsed(from: attempt.startedAt, to: attempt.readyAt),
                    readyToPlaying: elapsed(from: attempt.readyAt, to: attempt.playingAt),
                    switchToPlaying: elapsed(from: attempt.startedAt, to: attempt.playingAt),
                    switchToActive: elapsed(from: attempt.startedAt, to: attempt.activeAt)
                )
            }
            return TrackSwitchStats(
                requestedCount: requestedCount,
                completedCount: completedCount,
                latest: latest
            )
        }

        private mutating func update(_ body: (inout Attempt) -> Void) {
            guard var attempt = latestAttempt else { return }
            body(&attempt)
            latestAttempt = attempt
        }

        private func elapsed(
            from start: ContinuousClock.Instant?,
            to end: ContinuousClock.Instant?
        ) -> Duration? {
            guard let start, let end else { return nil }
            return start.duration(to: end)
        }
    }

    private struct FrameArrivalState {
        var lastWallNs: UInt64?
        var lastPtsUs: UInt64?
        var highestPtsUs: UInt64?

        var frameTimestamps: [UInt64] = []
        var intervalsWindow: [(ns: UInt64, duration: Duration)] = []
        var intervalTotal: Duration = .zero

        var slowArrivalCount: UInt64 = 0
        var fastArrivalCount: UInt64 = 0
        var outOfOrderCount: UInt64 = 0
        var maxOutOfOrderDelta: Duration?
        var discontinuityCount: UInt64 = 0
        var maxDiscontinuityGap: Duration?

        var hasData: Bool {
            !frameTimestamps.isEmpty || slowArrivalCount > 0 || fastArrivalCount > 0
                || outOfOrderCount > 0 || discontinuityCount > 0
        }

        mutating func resetTimingBaseline() {
            lastWallNs = nil
            lastPtsUs = nil
            highestPtsUs = nil
        }
    }

    private struct TimeToFirstPlaybackState: Sendable {
        var audioFrame: Duration?
        var videoFrame: Duration?
        var audioPlaying: Duration?
        var videoPlaying: Duration?

        func stats() -> TimeToFirstPlaybackStats {
            TimeToFirstPlaybackStats(
                audioFrame: audioFrame,
                videoFrame: videoFrame,
                audioPlaying: audioPlaying,
                videoPlaying: videoPlaying
            )
        }
    }

    // MARK: - Stored state

    private let lock = UnfairLock()
    private let wallClock: any PlaybackWallClock
    private let events: PlayerEventHub
    private let instantOrigin: ContinuousClock.Instant
    private let wallClockOriginNs: Int64

    private var rebufferKind: MediaFrameKind?
    private var hasPlaybackStartEmitted = false
    private var isRebuffering = false

    // Bitrate — 1-sec rolling window
    private var audioBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var audioBytesTotal: Int = 0
    private var videoBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var videoBytesTotal: Int = 0

    // FPS — displayed video, 1-sec rolling window
    private var videoFrameTimestamps: [UInt64] = []

    // Received-frame arrival diagnostics (one shared state per kind; reset on track start)
    private var audioArrival = FrameArrivalState()
    private var videoArrival = FrameArrivalState()

    // Dropped frames
    private var audioFramesDropped: UInt64 = 0
    private var videoFramesDropped: UInt64 = 0

    // Stalls / TTFF / switches
    private var playbackRequestedAt: ContinuousClock.Instant?
    private var timeToFirst = TimeToFirstPlaybackState()
    private var audioStalls = TrackStallState()
    private var videoStalls = TrackStallState()
    private var audioSwitches = TrackSwitchState()
    private var videoSwitches = TrackSwitchState()

    // Pending audio-playback handoff (set by ingest, consumed by audio render callback)
    private var pendingAudioPlaybackStart: PlaybackStartContext?
    /// Non-locking probe consulted from the audio render callback. Reads are byte-aligned
    /// and treated as relaxed; the lock is still taken when a handoff is in flight.
    private nonisolated(unsafe) var hasPendingAudioStart: Bool = false

    // Subscribers
    private var statsListeners: [UUID: @MainActor @Sendable (PlaybackStats) -> Void] = [:]
    private var latestSamples: PlaybackStats = .empty
    private var hasPublishedSample = false

    private static let windowNs: UInt64 = 1_000_000_000
    private static let minWindowSpanNs: UInt64 = 100_000_000
    private static let arrivalGapFactor: Double = 2.0
    private static let burstFactor: Double = 0.3
    private static let discontinuityThresholdUs: UInt64 = 2_000_000

    init(
        events: PlayerEventHub,
        wallClock: any PlaybackWallClock = HostPlaybackWallClock()
    ) {
        self.events = events
        self.wallClock = wallClock
        self.instantOrigin = ContinuousClock().now
        self.wallClockOriginNs = wallClock.now(in: .ns)
    }

    // MARK: - Session lifecycle

    /// Called from `Player.play()` together with `events.emit(.playbackRequest, ...)`.
    /// Records the request time used to derive TTFF, and resets per-session counters.
    func beginSession(rebufferKind: MediaFrameKind) {
        lock.withLock {
            self.rebufferKind = rebufferKind
            hasPlaybackStartEmitted = false
            isRebuffering = false
            playbackRequestedAt = nowInstant()
            timeToFirst = TimeToFirstPlaybackState()
            audioStalls = TrackStallState()
            videoStalls = TrackStallState()
            audioSwitches = TrackSwitchState()
            videoSwitches = TrackSwitchState()
            pendingAudioPlaybackStart = nil
            hasPendingAudioStart = false
        }
    }

    /// Called on permanent teardown — fully resets state and notifies subscribers with
    /// an empty snapshot.
    func reset() {
        let listeners: [@MainActor @Sendable (PlaybackStats) -> Void] = lock.withLock {
            audioBytesWindow.removeAll(); audioBytesTotal = 0
            videoBytesWindow.removeAll(); videoBytesTotal = 0
            videoFrameTimestamps.removeAll()
            audioArrival = FrameArrivalState()
            videoArrival = FrameArrivalState()
            audioFramesDropped = 0
            videoFramesDropped = 0
            playbackRequestedAt = nil
            timeToFirst = TimeToFirstPlaybackState()
            audioStalls = TrackStallState()
            videoStalls = TrackStallState()
            audioSwitches = TrackSwitchState()
            videoSwitches = TrackSwitchState()
            pendingAudioPlaybackStart = nil
            hasPendingAudioStart = false
            hasPlaybackStartEmitted = false
            isRebuffering = false
            rebufferKind = nil
            latestSamples = .empty
            hasPublishedSample = false
            return Array(statsListeners.values)
        }
        notify(listeners, stats: .empty)
    }

    /// Closes out any in-flight stall — used by Player when emitting playbackEnd /
    /// playerDestroy so rebufferingRatio doesn't accrue indefinitely.
    func closeOutInFlightStalls() {
        let instant = nowInstant()
        lock.withLock {
            audioStalls.end(at: instant)
            audioStalls.active = false
            videoStalls.end(at: instant)
            videoStalls.active = false
            isRebuffering = false
        }
    }

    // MARK: - Track lifecycle (called by PlaybackPipeline)

    func emitSubscribeStart(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSubscribeStart,
            attributes: PlayerEventAttributes.track(
                kind: kind, trackName: trackName, trackEpoch: trackEpoch
            )
        )
        let instant = nowInstant()
        guard trackEpoch > 1 else { return }
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.start(trackName: trackName, at: instant)
            case .video: videoSwitches.start(trackName: trackName, at: instant)
            }
        }
    }

    func emitSubscribeError(kind: MediaFrameKind, trackName: String, message: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSubscribeError,
            attributes: PlayerEventAttributes.track(
                kind: kind, trackName: trackName, message: message, trackEpoch: trackEpoch
            )
        )
        guard trackEpoch > 1 else { return }
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.markError(message)
            case .video: videoSwitches.markError(message)
            }
        }
    }

    func emitSubscribeEnd(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSubscribeEnd,
            attributes: PlayerEventAttributes.track(
                kind: kind, trackName: trackName, trackEpoch: trackEpoch
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
            .trackReady,
            attributes: PlayerEventAttributes.track(
                kind: kind,
                trackName: trackName,
                trackEpoch: trackEpoch,
                sourceTimestampUs: sourceTimestampUs,
                targetBuffering: targetBuffering,
                keyframe: keyframe,
                payloadBytes: payloadBytes
            )
        )
        let instant = nowInstant()
        lock.withLock {
            if trackEpoch == 1, let requestedAt = playbackRequestedAt {
                let duration = requestedAt.duration(to: instant)
                switch kind {
                case .audio:
                    if timeToFirst.audioFrame == nil { timeToFirst.audioFrame = duration }
                case .video:
                    if timeToFirst.videoFrame == nil { timeToFirst.videoFrame = duration }
                }
            }
            if trackEpoch > 1 {
                switch kind {
                case .audio: audioSwitches.markReady(at: instant)
                case .video: videoSwitches.markReady(at: instant)
                }
            }
        }
    }

    /// Emits `.trackSwitch` — called by audio ingest on first frame after a switch
    /// and by the video renderer when it cuts over to the pending track.
    func emitTrackSwitch(kind: MediaFrameKind, trackName: String, trackEpoch: TrackEpoch) {
        events.emit(
            .trackSwitch,
            attributes: PlayerEventAttributes.track(
                kind: kind, trackName: trackName, trackEpoch: trackEpoch
            )
        )
        let instant = nowInstant()
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.markActive(at: instant)
            case .video: videoSwitches.markActive(at: instant)
            }
        }
    }

    func emitDecodeError(kind: MediaFrameKind, trackName: String, message: String) {
        events.emit(
            .decodeError,
            attributes: PlayerEventAttributes.track(kind: kind, trackName: trackName, message: message)
        )
    }

    /// Emits `.playbackEnd`. Player calls this on permanent teardown; the pipeline
    /// coordinator task calls this when all upstream tracks end naturally.
    func emitPlaybackEnd(reason: String? = nil) {
        var attributes: [String: PlayerEventValue] = [:]
        if let reason { attributes["reason"] = .string(reason) }
        events.emit(.playbackEnd, attributes: attributes)
    }

    /// Emits a player-level event (lifecycle events emitted from `Player`).
    func emit(_ name: PlayerEventName, attributes: [String: PlayerEventValue] = [:]) {
        events.emit(name, attributes: attributes)
    }

    /// Subscribe to all events.
    func subscribeEvents(
        _ listener: @escaping @MainActor @Sendable (PlayerEvent) -> Void
    ) -> PlayerEventSubscription {
        events.subscribe(listener)
    }

    // MARK: - Stalls

    func audioStallBegan() { reportStall(kind: .audio, stalled: true) }
    func audioStallEnded() { reportStall(kind: .audio, stalled: false) }
    func videoStallBegan() { reportStall(kind: .video, stalled: true) }
    func videoStallEnded() { reportStall(kind: .video, stalled: false) }

    private func reportStall(kind: MediaFrameKind, stalled: Bool) {
        let outcome = lock.withLock { () -> (trackEvent: PlayerEventName, rebufferEvent: PlayerEventName?, attributes: [String: PlayerEventValue])? in
            let wasStalled: Bool
            switch kind {
            case .audio: wasStalled = audioStalls.active
            case .video: wasStalled = videoStalls.active
            }
            guard wasStalled != stalled else { return nil }

            let instant = nowInstant()
            switch kind {
            case .audio:
                audioStalls.active = stalled
                stalled ? audioStalls.start(at: instant) : audioStalls.end(at: instant)
            case .video:
                videoStalls.active = stalled
                stalled ? videoStalls.start(at: instant) : videoStalls.end(at: instant)
            }

            var rebufferEvent: PlayerEventName?
            if kind == rebufferKind, isRebuffering != stalled {
                isRebuffering = stalled
                rebufferEvent = stalled ? .rebufferStart : .rebufferEnd
            }
            return (
                stalled ? .trackStallStart : .trackStallEnd,
                rebufferEvent,
                PlayerEventAttributes.track(kind: kind)
            )
        }

        guard let outcome else { return }
        events.emit(outcome.trackEvent, attributes: outcome.attributes)
        if let rebufferEvent = outcome.rebufferEvent {
            events.emit(rebufferEvent, attributes: outcome.attributes)
        }
    }

    // MARK: - First-frame playback handoff (audio)

    func expectAudioPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        lock.withLock {
            pendingAudioPlaybackStart = PlaybackStartContext(
                kind: .audio,
                trackName: trackName,
                sourceTimestampUs: sourceTimestampUs,
                targetBuffering: targetBuffering,
                trackEpoch: trackEpoch
            )
            hasPendingAudioStart = true
        }
    }

    func clearExpectedAudioPlaybackStart() {
        lock.withLock {
            pendingAudioPlaybackStart = nil
            hasPendingAudioStart = false
        }
    }

    /// **Test-only.** Production audio rendering MUST emit playback-started
    /// through `AudioRenderEventBridge` to keep the realtime audio
    /// thread free of locks, Obj-C calls, and listener fan-out. Do not call
    /// this from non-test code.
    func audioPlaybackStartedIfExpected(
        renderedTimestampUs: UInt64,
        outputHostTime: UInt64?,
        outputPresentationLatencyMs: Double?
    ) {
        guard hasPendingAudioStart else { return }
        let context = lock.withLock { () -> PlaybackStartContext? in
            guard let context = pendingAudioPlaybackStart,
                  renderedTimestampUs >= context.sourceTimestampUs
            else { return nil }
            pendingAudioPlaybackStart = nil
            hasPendingAudioStart = false
            return context
        }
        guard let context else { return }

        audioPlaybackStarted(
            context: context,
            renderedTimestampUs: renderedTimestampUs,
            outputHostTime: outputHostTime,
            outputPresentationLatencyMs: outputPresentationLatencyMs
        )
    }

    /// Emits the audio first-frame playback-started event from the bridge queue.
    ///
    /// `renderedTimestampUs` and `outputHostTime` are sampled precisely on the audio render
    /// thread, but the event emission itself is deferred to `AudioRenderEventBridge`.
    func audioPlaybackStarted(
        context: PlaybackStartContext,
        renderedTimestampUs: UInt64,
        outputHostTime: UInt64?,
        outputPresentationLatencyMs: Double?
    ) {
        emitTrackPlaying(context: context) { attributes in
            attributes["renderedTimestampUs"] = .uint(renderedTimestampUs)
            if let outputHostTime {
                attributes["outputHostTime"] = .uint(outputHostTime)
            }
            if let outputPresentationLatencyMs {
                attributes["outputPresentationLatencyMs"] = .double(outputPresentationLatencyMs)
            }
        }
    }

    /// Called from the video display-link observer on first visible frame.
    func videoPlaybackStarted(
        context: PlaybackStartContext,
        presentationTimeUs: UInt64,
        clockTimeUs: UInt64,
        bufferMs: Double
    ) {
        emitTrackPlaying(context: context) { attributes in
            attributes["presentationTimeUs"] = .uint(presentationTimeUs)
            attributes["clockTimeUs"] = .uint(clockTimeUs)
            attributes["bufferMs"] = .double(bufferMs)
        }
    }

    private func emitTrackPlaying(
        context: PlaybackStartContext,
        update: (inout [String: PlayerEventValue]) -> Void
    ) {
        var attributes = PlayerEventAttributes.track(
            kind: context.kind,
            trackName: context.trackName,
            trackEpoch: context.trackEpoch,
            sourceTimestampUs: context.sourceTimestampUs,
            targetBuffering: context.targetBuffering
        )
        update(&attributes)
        events.emit(.trackPlaying, attributes: attributes)
        let instant = nowInstant()

        // Update TTFF + switch milestones, then decide whether playbackStart should
        // fire — only for the configured rebufferKind, deterministic regardless of
        // audio/video race ordering.
        let shouldEmitPlaybackStart: Bool = lock.withLock {
            if context.trackEpoch == 1, let requestedAt = playbackRequestedAt {
                let duration = requestedAt.duration(to: instant)
                switch context.kind {
                case .audio:
                    if timeToFirst.audioPlaying == nil { timeToFirst.audioPlaying = duration }
                case .video:
                    if timeToFirst.videoPlaying == nil { timeToFirst.videoPlaying = duration }
                }
            }
            switch context.kind {
            case .audio:
                audioStalls.markReady(at: instant)
            case .video:
                videoStalls.markReady(at: instant)
            }
            if context.trackEpoch > 1 {
                switch context.kind {
                case .audio: audioSwitches.markPlaying(at: instant)
                case .video: videoSwitches.markPlaying(at: instant)
                }
                return false
            }
            guard !hasPlaybackStartEmitted, context.kind == rebufferKind else { return false }
            hasPlaybackStartEmitted = true
            return true
        }
        if shouldEmitPlaybackStart {
            events.emit(.playbackStart, attributes: attributes)
        }
    }

    // MARK: - FPS / dropped frames

    func recordVideoFrameDisplayed() {
        lock.withLock {
            let now = nowNs()
            videoFrameTimestamps.append(now)
            pruneTimestamps(entries: &videoFrameTimestamps, now: now)
        }
    }

    func recordVideoFrameDropped() {
        lock.withLock { videoFramesDropped += 1 }
    }

    func recordAudioFramesDropped(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { audioFramesDropped += UInt64(count) }
    }

    // MARK: - MediaFrameObserver

    func onMediaTrackStarted(kind: MediaFrameKind) {
        lock.withLock {
            switch kind {
            case .audio:
                audioArrival.resetTimingBaseline()
            case .video:
                videoArrival.resetTimingBaseline()
            }
        }
    }

    func onMediaFrame(kind: MediaFrameKind, frame: MediaFrame) {
        lock.withLock {
            let now = nowNs()
            switch kind {
            case .audio:
                audioBytesWindow.append((ns: now, bytes: frame.payload.count))
                audioBytesTotal += frame.payload.count
                pruneWindow(entries: &audioBytesWindow, total: &audioBytesTotal, now: now)
                recordArrival(frame: frame, now: now, state: &audioArrival)
            case .video:
                videoBytesWindow.append((ns: now, bytes: frame.payload.count))
                videoBytesTotal += frame.payload.count
                pruneWindow(entries: &videoBytesWindow, total: &videoBytesTotal, now: now)
                recordArrival(frame: frame, now: now, state: &videoArrival)
            }
        }
    }

    func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        lock.withLock {
            let gap = Duration.microsecondsClamped(gapUs)
            switch kind {
            case .audio:
                audioArrival.discontinuityCount += 1
                audioArrival.maxDiscontinuityGap = maxDuration(
                    audioArrival.maxDiscontinuityGap,
                    gap
                )
                audioArrival.resetTimingBaseline()
            case .video:
                videoArrival.discontinuityCount += 1
                videoArrival.maxDiscontinuityGap = maxDuration(
                    videoArrival.maxDiscontinuityGap,
                    gap
                )
                videoArrival.resetTimingBaseline()
            }
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

    /// Called by `Player` on its 1 Hz sampling tick. Replaces `latestSamples`, recomputes
    /// the full snapshot, and pushes to all stats listeners.
    func publishSample(_ samples: PlaybackStats) {
        let update: (PlaybackStats, [@MainActor @Sendable (PlaybackStats) -> Void]) = lock.withLock {
            latestSamples = samples
            hasPublishedSample = true
            let stats = makeStatsLocked(
                audioLatency: samples.audioLatency,
                videoLatency: samples.videoLatency,
                audioRingBuffer: samples.audioRingBuffer,
                videoJitterBuffer: samples.videoJitterBuffer,
                instant: nowInstant()
            )
            return (stats, Array(statsListeners.values))
        }
        notify(update.1, stats: update.0)
    }

    func currentStats() -> PlaybackStats {
        lock.withLock {
            makeStatsLocked(
                audioLatency: latestSamples.audioLatency,
                videoLatency: latestSamples.videoLatency,
                audioRingBuffer: latestSamples.audioRingBuffer,
                videoJitterBuffer: latestSamples.videoJitterBuffer,
                instant: nowInstant()
            )
        }
    }

    func subscribeStats(
        _ listener: @escaping @MainActor @Sendable (PlaybackStats) -> Void
    ) -> PlayerEventSubscription {
        let id = UUID()
        let initialStats = lock.withLock { () -> PlaybackStats? in
            statsListeners[id] = listener
            return hasPublishedSample ? makeStatsLocked(
                audioLatency: latestSamples.audioLatency,
                videoLatency: latestSamples.videoLatency,
                audioRingBuffer: latestSamples.audioRingBuffer,
                videoJitterBuffer: latestSamples.videoJitterBuffer,
                instant: nowInstant()
            ) : nil
        }
        if let initialStats {
            Task { @MainActor in
                listener(initialStats)
            }
        }
        return PlayerEventSubscription { [weak self] in
            self?.lock.withLock {
                self?.statsListeners[id] = nil
            }
        }
    }

    // MARK: - Stats assembly (called under lock)

    private func makeStatsLocked(
        audioLatency: Duration?,
        videoLatency: Duration?,
        audioRingBuffer: Duration?,
        videoJitterBuffer: Duration?,
        instant: ContinuousClock.Instant
    ) -> PlaybackStats {
        let now = nowNs()
        let audioBitrateKbps = computeBitrateKbps(
            entries: audioBytesWindow, total: audioBytesTotal, now: now)
        let videoBitrateKbps = computeBitrateKbps(
            entries: videoBytesWindow, total: videoBytesTotal, now: now)
        let fps = computeFps(entries: videoFrameTimestamps, now: now)

        return PlaybackStats(
            audioLatency: audioLatency,
            videoLatency: videoLatency,
            audioStalls: audioStalls.stats(at: instant),
            videoStalls: videoStalls.stats(at: instant),
            audioBitrateKbps: audioBitrateKbps,
            videoBitrateKbps: videoBitrateKbps,
            timeToFirst: timeToFirst.stats(),
            videoFps: fps,
            audioFramesDropped: audioFramesDropped > 0 ? audioFramesDropped : nil,
            videoFramesDropped: videoFramesDropped > 0 ? videoFramesDropped : nil,
            audioRingBuffer: audioRingBuffer,
            videoJitterBuffer: videoJitterBuffer,
            audioArrival: makeFrameArrivalStats(audioArrival, now: now),
            videoArrival: makeFrameArrivalStats(videoArrival, now: now),
            audioSwitches: audioSwitches.stats(),
            videoSwitches: videoSwitches.stats()
        )
    }

    // MARK: - Private helpers (called under lock)

    private func recordArrival(
        frame: MediaFrame,
        now: UInt64,
        state: inout FrameArrivalState
    ) {
        state.frameTimestamps.append(now)
        pruneTimestamps(entries: &state.frameTimestamps, now: now)
        pruneArrivalIntervals(state: &state, now: now)

        if let highest = state.highestPtsUs, frame.timestampUs < highest {
            state.outOfOrderCount += 1
            let delta = Duration.microsecondsClamped(highest - frame.timestampUs)
            state.maxOutOfOrderDelta = maxDuration(state.maxOutOfOrderDelta, delta)
        }
        state.highestPtsUs = max(state.highestPtsUs ?? 0, frame.timestampUs)

        if let previousWallNs = state.lastWallNs, let previousPtsUs = state.lastPtsUs {
            let isOutOfOrder = frame.timestampUs < previousPtsUs
            let ptsDeltaUs = isOutOfOrder ? 0 : frame.timestampUs - previousPtsUs

            if !isOutOfOrder,
                ptsDeltaUs <= Self.discontinuityThresholdUs,
                let wallDeltaNs = Self.elapsedNs(from: previousWallNs, to: now)
            {
                let wallDelta = Duration.nanosecondsClamped(wallDeltaNs)
                state.intervalsWindow.append((ns: now, duration: wallDelta))
                state.intervalTotal += wallDelta
                pruneArrivalIntervals(state: &state, now: now)

                let ptsDeltaMs = Double(ptsDeltaUs) / 1_000.0
                if ptsDeltaMs > 0 {
                    let wallDeltaMs = wallDelta.milliseconds
                    if wallDeltaMs > ptsDeltaMs * Self.arrivalGapFactor {
                        state.slowArrivalCount += 1
                    } else if wallDeltaMs < ptsDeltaMs * Self.burstFactor {
                        state.fastArrivalCount += 1
                    }
                }
            }
        }

        state.lastWallNs = now
        state.lastPtsUs = frame.timestampUs
    }

    private func pruneWindow(
        entries: inout [(ns: UInt64, bytes: Int)], total: inout Int, now: UInt64
    ) {
        let cutoff = now >= Self.windowNs ? now - Self.windowNs : 0
        while let first = entries.first, first.ns < cutoff {
            total -= first.bytes
            entries.removeFirst()
        }
    }

    private func pruneTimestamps(entries: inout [UInt64], now: UInt64) {
        let cutoff = now >= Self.windowNs ? now - Self.windowNs : 0
        while let first = entries.first, first < cutoff {
            entries.removeFirst()
        }
    }

    private func pruneArrivalIntervals(state: inout FrameArrivalState, now: UInt64) {
        let cutoff = now >= Self.windowNs ? now - Self.windowNs : 0
        while let first = state.intervalsWindow.first, first.ns < cutoff {
            state.intervalTotal -= first.duration
            state.intervalsWindow.removeFirst()
        }
    }

    private func computeBitrateKbps(entries: [(ns: UInt64, bytes: Int)], total: Int, now: UInt64)
        -> Double?
    {
        guard let first = entries.first else { return nil }
        guard let spanNs = Self.elapsedNs(from: first.ns, to: now) else { return nil }
        guard spanNs > Self.minWindowSpanNs else { return nil }
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(total) * 8.0 / 1000.0 / spanSec
    }

    private func computeFps(entries: [UInt64], now: UInt64) -> Double? {
        guard entries.count >= 2, let first = entries.first else { return nil }
        guard let spanNs = Self.elapsedNs(from: first, to: now) else { return nil }
        guard spanNs > Self.minWindowSpanNs else { return nil }
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(entries.count) / spanSec
    }

    private func makeFrameArrivalStats(_ state: FrameArrivalState, now: UInt64)
        -> FrameArrivalStats?
    {
        guard state.hasData else { return nil }

        let averageInterarrival =
            state.intervalsWindow.count > 0
            ? state.intervalTotal / state.intervalsWindow.count : nil
        let maxInterarrival = state.intervalsWindow.map(\.duration).max()

        return FrameArrivalStats(
            receivedFramesPerSecond: computeFps(entries: state.frameTimestamps, now: now),
            averageInterarrival: averageInterarrival,
            maxInterarrival: maxInterarrival,
            slowArrivalCount: state.slowArrivalCount,
            fastArrivalCount: state.fastArrivalCount,
            outOfOrderCount: state.outOfOrderCount,
            maxOutOfOrderDelta: state.maxOutOfOrderDelta,
            discontinuityCount: state.discontinuityCount,
            maxDiscontinuityGap: state.maxDiscontinuityGap
        )
    }

    private func maxDuration(_ lhs: Duration?, _ rhs: Duration) -> Duration {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static func elapsedNs(from start: UInt64, to end: UInt64) -> UInt64? {
        let elapsed = end.subtractingReportingOverflow(start)
        return elapsed.overflow ? nil : elapsed.partialValue
    }

    private func nowNs() -> UInt64 {
        UInt64(max(0, wallClock.now(in: .ns)))
    }

    private func nowInstant() -> ContinuousClock.Instant {
        let elapsedNs: Int64
        let nowNs = wallClock.now(in: .ns)
        let result = nowNs.subtractingReportingOverflow(wallClockOriginNs)
        if result.overflow {
            elapsedNs = nowNs >= wallClockOriginNs ? Int64.max : 0
        } else {
            elapsedNs = max(0, result.partialValue)
        }
        return instantOrigin.advanced(by: .nanoseconds(elapsedNs))
    }

    private func notify(
        _ listeners: [@MainActor @Sendable (PlaybackStats) -> Void],
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
