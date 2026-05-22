import Foundation

struct PlaybackStartContext: Sendable {
    let kind: MediaFrameKind
    let trackName: String
    let sourceTimestampUs: UInt64
    let targetBufferingMs: UInt64
    let isSwitch: Bool
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
        var readyAtMs: Double?
        var activeStallStartedAtMs: Double?
        var stallCount: UInt64 = 0
        var totalStallMs: Double = 0
        var isStalled: Bool = false

        mutating func markReady(at timestampMs: Double) {
            if readyAtMs == nil {
                readyAtMs = timestampMs
            }
        }

        mutating func startStall(at timestampMs: Double) {
            markReady(at: timestampMs)
            guard activeStallStartedAtMs == nil else { return }
            activeStallStartedAtMs = timestampMs
            stallCount += 1
        }

        mutating func endStall(at timestampMs: Double) {
            guard let startedAt = activeStallStartedAtMs else {
                markReady(at: timestampMs)
                return
            }
            totalStallMs += max(0, timestampMs - startedAt)
            activeStallStartedAtMs = nil
        }

        mutating func endActiveStall(at timestampMs: Double) {
            if activeStallStartedAtMs != nil {
                endStall(at: timestampMs)
            }
        }

        func stats(at timestampMs: Double) -> StallStats? {
            guard let readyAtMs else { return nil }

            var total = totalStallMs
            if let activeStallStartedAtMs {
                total += max(0, timestampMs - activeStallStartedAtMs)
            }
            let elapsed = max(0, timestampMs - readyAtMs)
            let ratio = elapsed > 0 ? total / elapsed : 0
            return StallStats(
                count: stallCount,
                totalDurationMs: total,
                rebufferingRatio: ratio
            )
        }
    }

    private struct TrackSwitchState: Sendable {
        private struct Attempt: Sendable {
            var trackName: String?
            var startedAtMs: Double
            var readyAtMs: Double?
            var frameAtMs: Double?
            var playingAtMs: Double?
            var activeAtMs: Double?
            var errorMessage: String?
        }

        private var latestAttempt: Attempt?
        private var didCountLatestCompletion = false
        var requestedCount: UInt64 = 0
        var completedCount: UInt64 = 0

        mutating func start(trackName: String?, at timestampMs: Double) {
            requestedCount += 1
            latestAttempt = Attempt(
                trackName: trackName,
                startedAtMs: timestampMs
            )
            didCountLatestCompletion = false
        }

        mutating func markReady(at timestampMs: Double) {
            update { attempt in
                attempt.readyAtMs = attempt.readyAtMs ?? timestampMs
            }
        }

        mutating func markFrame(at timestampMs: Double) {
            update { attempt in
                attempt.frameAtMs = attempt.frameAtMs ?? timestampMs
            }
        }

        mutating func markPlaying(at timestampMs: Double) {
            update { attempt in
                attempt.playingAtMs = attempt.playingAtMs ?? timestampMs
            }
        }

        mutating func markActive(at timestampMs: Double) {
            update { attempt in
                attempt.activeAtMs = attempt.activeAtMs ?? timestampMs
            }
            guard latestAttempt?.activeAtMs != nil, !didCountLatestCompletion else { return }
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
                    isCompleted: attempt.activeAtMs != nil,
                    errorMessage: attempt.errorMessage,
                    switchToReadyMs: elapsed(from: attempt.startedAtMs, to: attempt.readyAtMs),
                    switchToFrameMs: elapsed(from: attempt.startedAtMs, to: attempt.frameAtMs),
                    readyToFrameMs: elapsed(from: attempt.readyAtMs, to: attempt.frameAtMs),
                    frameToPlayingMs: elapsed(from: attempt.frameAtMs, to: attempt.playingAtMs),
                    switchToPlayingMs: elapsed(from: attempt.startedAtMs, to: attempt.playingAtMs),
                    switchToActiveMs: elapsed(from: attempt.startedAtMs, to: attempt.activeAtMs)
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

        private func elapsed(from start: Double?, to end: Double?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end - start)
        }
    }

    private struct FrameArrivalState {
        var lastWallNs: UInt64?
        var lastPtsUs: UInt64?
        var highestPtsUs: UInt64?

        var frameTimestamps: [UInt64] = []
        var intervalsWindow: [(ns: UInt64, ms: Double)] = []
        var intervalMsTotal: Double = 0

        var slowArrivalCount: UInt64 = 0
        var fastArrivalCount: UInt64 = 0
        var outOfOrderCount: UInt64 = 0
        var maxOutOfOrderDeltaMs: Double = 0
        var discontinuityCount: UInt64 = 0
        var maxDiscontinuityGapMs: Double = 0

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

    // MARK: - Stored state

    private let lock = UnfairLock()
    private let wallClock: any PlaybackWallClock
    private let events: PlayerEventHub

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
    private var playbackRequestedAtMs: Double?
    private var timeToFirstAudioFrameMs: Double?
    private var timeToFirstVideoFrameMs: Double?
    private var timeToFirstAudioPlayingMs: Double?
    private var timeToFirstVideoPlayingMs: Double?
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
    }

    // MARK: - Session lifecycle

    /// Called from `Player.play()` together with `events.emit(.playbackRequest, ...)`.
    /// Records the request time used to derive TTFF, and resets per-session counters.
    func beginSession(rebufferKind: MediaFrameKind, at timestampMs: Double) {
        lock.withLock {
            self.rebufferKind = rebufferKind
            hasPlaybackStartEmitted = false
            isRebuffering = false
            playbackRequestedAtMs = timestampMs
            timeToFirstAudioFrameMs = nil
            timeToFirstVideoFrameMs = nil
            timeToFirstAudioPlayingMs = nil
            timeToFirstVideoPlayingMs = nil
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
            playbackRequestedAtMs = nil
            timeToFirstAudioFrameMs = nil
            timeToFirstVideoFrameMs = nil
            timeToFirstAudioPlayingMs = nil
            timeToFirstVideoPlayingMs = nil
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
        let timestampMs = PlayerEventHub.timestampMs()
        lock.withLock {
            audioStalls.endActiveStall(at: timestampMs)
            videoStalls.endActiveStall(at: timestampMs)
        }
    }

    // MARK: - Track lifecycle (called by PlaybackPipeline)

    func emitSubscribeStart(kind: MediaFrameKind, trackName: String, isSwitch: Bool) {
        let event = events.emit(
            .trackSubscribeStart,
            attributes: PlayerEventAttributes.track(kind: kind, trackName: trackName, isSwitch: isSwitch)
        )
        guard isSwitch else { return }
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.start(trackName: trackName, at: event.timestampMs)
            case .video: videoSwitches.start(trackName: trackName, at: event.timestampMs)
            }
        }
    }

    func emitSubscribeReady(kind: MediaFrameKind, trackName: String, isSwitch: Bool) {
        let event = events.emit(
            .trackSubscribeReady,
            attributes: PlayerEventAttributes.track(kind: kind, trackName: trackName, isSwitch: isSwitch)
        )
        guard isSwitch else { return }
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.markReady(at: event.timestampMs)
            case .video: videoSwitches.markReady(at: event.timestampMs)
            }
        }
    }

    func emitSubscribeError(kind: MediaFrameKind, trackName: String, message: String, isSwitch: Bool) {
        events.emit(
            .trackSubscribeError,
            attributes: PlayerEventAttributes.track(
                kind: kind, trackName: trackName, message: message, isSwitch: isSwitch
            )
        )
        guard isSwitch else { return }
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.markError(message)
            case .video: videoSwitches.markError(message)
            }
        }
    }

    func emitSubscribeEnd(kind: MediaFrameKind, trackName: String) {
        events.emit(
            .trackSubscribeEnd,
            attributes: PlayerEventAttributes.track(kind: kind, trackName: trackName)
        )
    }

    /// Called by an ingest task on the first accepted/decoded frame. Emits
    /// `.trackFrameReady` and updates TTFF / switch milestones.
    func emitFrameReady(
        kind: MediaFrameKind,
        trackName: String,
        isSwitch: Bool,
        sourceTimestampUs: UInt64,
        targetBufferingMs: UInt64,
        keyframe: Bool,
        payloadBytes: Int
    ) {
        let event = events.emit(
            .trackFrameReady,
            attributes: PlayerEventAttributes.track(
                kind: kind,
                trackName: trackName,
                isSwitch: isSwitch,
                sourceTimestampUs: sourceTimestampUs,
                targetBufferingMs: targetBufferingMs,
                keyframe: keyframe,
                payloadBytes: payloadBytes
            )
        )
        lock.withLock {
            if !isSwitch, let requestedAt = playbackRequestedAtMs {
                let delta = max(0, event.timestampMs - requestedAt)
                switch kind {
                case .audio:
                    if timeToFirstAudioFrameMs == nil { timeToFirstAudioFrameMs = delta }
                case .video:
                    if timeToFirstVideoFrameMs == nil { timeToFirstVideoFrameMs = delta }
                }
            }
            if isSwitch {
                switch kind {
                case .audio: audioSwitches.markFrame(at: event.timestampMs)
                case .video: videoSwitches.markFrame(at: event.timestampMs)
                }
            }
        }
    }

    /// Emits `.qualityChange` — called by audio ingest on first frame after a switch
    /// and by the video renderer when it cuts over to the pending track.
    func emitQualityChange(kind: MediaFrameKind, trackName: String) {
        let event = events.emit(
            .qualityChange,
            attributes: PlayerEventAttributes.track(kind: kind, trackName: trackName, isSwitch: true)
        )
        lock.withLock {
            switch kind {
            case .audio: audioSwitches.markActive(at: event.timestampMs)
            case .video: videoSwitches.markActive(at: event.timestampMs)
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
            case .audio: wasStalled = audioStalls.isStalled
            case .video: wasStalled = videoStalls.isStalled
            }
            guard wasStalled != stalled else { return nil }

            let timestampMs = PlayerEventHub.timestampMs()
            switch kind {
            case .audio:
                audioStalls.isStalled = stalled
                stalled ? audioStalls.startStall(at: timestampMs) : audioStalls.endStall(at: timestampMs)
            case .video:
                videoStalls.isStalled = stalled
                stalled ? videoStalls.startStall(at: timestampMs) : videoStalls.endStall(at: timestampMs)
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
        targetBufferingMs: UInt64,
        isSwitch: Bool
    ) {
        lock.withLock {
            pendingAudioPlaybackStart = PlaybackStartContext(
                kind: .audio,
                trackName: trackName,
                sourceTimestampUs: sourceTimestampUs,
                targetBufferingMs: targetBufferingMs,
                isSwitch: isSwitch
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
    /// through `AudioRenderEventBridge.drain()` to keep the realtime audio
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

    /// Emits the audio first-frame playback-started event from the bridge timer.
    ///
    /// `renderedTimestampUs` and `outputHostTime` are sampled precisely on the audio render
    /// thread, but the *event emission itself* is deferred up to ~25 ms (one
    /// `AudioRenderEventBridge` timer tick). Consumers using `renderedTimestampUs` as a
    /// precise wall-clock anchor are unaffected; consumers using the event's own
    /// `timestampMs` for TTFF gain a bounded skew of ≤25 ms relative to the actual
    /// first-rendered moment.
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
            isSwitch: context.isSwitch,
            sourceTimestampUs: context.sourceTimestampUs,
            targetBufferingMs: context.targetBufferingMs
        )
        update(&attributes)
        let event = events.emit(.trackPlaying, attributes: attributes)

        // Update TTFF + switch milestones, then decide whether playbackStart should
        // fire — only for the configured rebufferKind, deterministic regardless of
        // audio/video race ordering.
        let shouldEmitPlaybackStart: Bool = lock.withLock {
            if !context.isSwitch, let requestedAt = playbackRequestedAtMs {
                let delta = max(0, event.timestampMs - requestedAt)
                switch context.kind {
                case .audio:
                    if timeToFirstAudioPlayingMs == nil { timeToFirstAudioPlayingMs = delta }
                case .video:
                    if timeToFirstVideoPlayingMs == nil { timeToFirstVideoPlayingMs = delta }
                }
            }
            switch context.kind {
            case .audio:
                audioStalls.markReady(at: event.timestampMs)
            case .video:
                videoStalls.markReady(at: event.timestampMs)
            }
            if context.isSwitch {
                switch context.kind {
                case .audio: audioSwitches.markPlaying(at: event.timestampMs)
                case .video: videoSwitches.markPlaying(at: event.timestampMs)
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

    func onMediaTrackStarted(kind: MediaFrameKind, trackName: String) {
        lock.withLock {
            switch kind {
            case .audio:
                audioArrival.resetTimingBaseline()
            case .video:
                videoArrival.resetTimingBaseline()
            }
        }
    }

    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind, trackName: String) {
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

    func onFrameDiscontinuity(kind: MediaFrameKind, trackName: String, gapUs: UInt64) {
        lock.withLock {
            let gapMs = Double(gapUs) / 1_000.0
            switch kind {
            case .audio:
                audioArrival.discontinuityCount += 1
                audioArrival.maxDiscontinuityGapMs = max(audioArrival.maxDiscontinuityGapMs, gapMs)
                audioArrival.resetTimingBaseline()
            case .video:
                videoArrival.discontinuityCount += 1
                videoArrival.maxDiscontinuityGapMs = max(videoArrival.maxDiscontinuityGapMs, gapMs)
                videoArrival.resetTimingBaseline()
            }
        }
    }

    // MARK: - Stats

    /// Combines sampled latency/buffer values supplied by the pipeline with all
    /// tracker-owned counters into a single `PlaybackStats`.
    func sampleStats(
        audioLatencyMs: Double?,
        videoLatencyMs: Double?,
        audioRingBufferMs: Double?,
        videoJitterBufferMs: Double?
    ) -> PlaybackStats {
        lock.withLock {
            let timestampMs = PlayerEventHub.timestampMs()
            return makeStatsLocked(
                audioLatencyMs: audioLatencyMs,
                videoLatencyMs: videoLatencyMs,
                audioRingBufferMs: audioRingBufferMs,
                videoJitterBufferMs: videoJitterBufferMs,
                timestampMs: timestampMs
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
                audioLatencyMs: samples.audioLatencyMs,
                videoLatencyMs: samples.videoLatencyMs,
                audioRingBufferMs: samples.audioRingBufferMs,
                videoJitterBufferMs: samples.videoJitterBufferMs,
                timestampMs: PlayerEventHub.timestampMs()
            )
            return (stats, Array(statsListeners.values))
        }
        notify(update.1, stats: update.0)
    }

    func currentStats() -> PlaybackStats {
        lock.withLock {
            makeStatsLocked(
                audioLatencyMs: latestSamples.audioLatencyMs,
                videoLatencyMs: latestSamples.videoLatencyMs,
                audioRingBufferMs: latestSamples.audioRingBufferMs,
                videoJitterBufferMs: latestSamples.videoJitterBufferMs,
                timestampMs: PlayerEventHub.timestampMs()
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
                audioLatencyMs: latestSamples.audioLatencyMs,
                videoLatencyMs: latestSamples.videoLatencyMs,
                audioRingBufferMs: latestSamples.audioRingBufferMs,
                videoJitterBufferMs: latestSamples.videoJitterBufferMs,
                timestampMs: PlayerEventHub.timestampMs()
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
        audioLatencyMs: Double?,
        videoLatencyMs: Double?,
        audioRingBufferMs: Double?,
        videoJitterBufferMs: Double?,
        timestampMs: Double
    ) -> PlaybackStats {
        let now = nowNs()
        let audioBitrateKbps = computeBitrateKbps(
            entries: audioBytesWindow, total: audioBytesTotal, now: now)
        let videoBitrateKbps = computeBitrateKbps(
            entries: videoBytesWindow, total: videoBytesTotal, now: now)
        let fps = computeFps(entries: videoFrameTimestamps, now: now)

        return PlaybackStats(
            audioLatencyMs: audioLatencyMs,
            videoLatencyMs: videoLatencyMs,
            audioStalls: audioStalls.stats(at: timestampMs),
            videoStalls: videoStalls.stats(at: timestampMs),
            audioBitrateKbps: audioBitrateKbps,
            videoBitrateKbps: videoBitrateKbps,
            timeToFirstAudioFrameMs: timeToFirstAudioFrameMs,
            timeToFirstVideoFrameMs: timeToFirstVideoFrameMs,
            timeToFirstAudioPlayingMs: timeToFirstAudioPlayingMs,
            timeToFirstVideoPlayingMs: timeToFirstVideoPlayingMs,
            videoFps: fps,
            audioFramesDropped: audioFramesDropped > 0 ? audioFramesDropped : nil,
            videoFramesDropped: videoFramesDropped > 0 ? videoFramesDropped : nil,
            audioRingBufferMs: audioRingBufferMs,
            videoJitterBufferMs: videoJitterBufferMs,
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
            let deltaMs = Double(highest - frame.timestampUs) / 1_000.0
            state.maxOutOfOrderDeltaMs = max(state.maxOutOfOrderDeltaMs, deltaMs)
        }
        state.highestPtsUs = max(state.highestPtsUs ?? 0, frame.timestampUs)

        if let previousWallNs = state.lastWallNs, let previousPtsUs = state.lastPtsUs {
            let isOutOfOrder = frame.timestampUs < previousPtsUs
            let ptsDeltaUs = isOutOfOrder ? 0 : frame.timestampUs - previousPtsUs

            if !isOutOfOrder,
                ptsDeltaUs <= Self.discontinuityThresholdUs,
                let wallDeltaNs = Self.elapsedNs(from: previousWallNs, to: now)
            {
                let wallDeltaMs = Double(wallDeltaNs) / 1_000_000.0
                state.intervalsWindow.append((ns: now, ms: wallDeltaMs))
                state.intervalMsTotal += wallDeltaMs
                pruneArrivalIntervals(state: &state, now: now)

                let ptsDeltaMs = Double(ptsDeltaUs) / 1_000.0
                if ptsDeltaMs > 0 {
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
            state.intervalMsTotal -= first.ms
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

        let averageInterarrivalMs =
            state.intervalsWindow.count > 0
            ? state.intervalMsTotal / Double(state.intervalsWindow.count) : nil
        let maxInterarrivalMs = state.intervalsWindow.map(\.ms).max()

        return FrameArrivalStats(
            receivedFramesPerSecond: computeFps(entries: state.frameTimestamps, now: now),
            averageInterarrivalMs: averageInterarrivalMs,
            maxInterarrivalMs: maxInterarrivalMs,
            slowArrivalCount: state.slowArrivalCount,
            fastArrivalCount: state.fastArrivalCount,
            outOfOrderCount: state.outOfOrderCount,
            maxOutOfOrderDeltaMs: state.maxOutOfOrderDeltaMs > 0
                ? state.maxOutOfOrderDeltaMs : nil,
            discontinuityCount: state.discontinuityCount,
            maxDiscontinuityGapMs: state.maxDiscontinuityGapMs > 0
                ? state.maxDiscontinuityGapMs : nil
        )
    }

    private static func elapsedNs(from start: UInt64, to end: UInt64) -> UInt64? {
        let elapsed = end.subtractingReportingOverflow(start)
        return elapsed.overflow ? nil : elapsed.partialValue
    }

    private func nowNs() -> UInt64 {
        UInt64(max(0, wallClock.now(in: .ns)))
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
