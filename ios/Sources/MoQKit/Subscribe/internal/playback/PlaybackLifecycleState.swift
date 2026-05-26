import Foundation

struct PlaybackLifecycleSnapshot: Sendable {
    let audioStalls: StallStats?
    let videoStalls: StallStats?
    let timeToFirst: TimeToFirstPlaybackStats
    let audioSwitches: TrackSwitchStats?
    let videoSwitches: TrackSwitchStats?
}

struct PlaybackStallChange: Sendable {
    let kind: MediaFrameKind
    let stalled: Bool
    let rebufferChanged: Bool
}

struct PlaybackLifecycleState: Sendable {
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

    private var rebufferKind: MediaFrameKind?
    private var hasPlaybackStartEmitted = false
    private var isRebuffering = false
    private var playbackRequestedAt: ContinuousClock.Instant?
    private var timeToFirst = TimeToFirstPlaybackState()
    private var stalls = PerMediaKind { TrackStallState() }
    private var switches = PerMediaKind { TrackSwitchState() }

    mutating func beginSession(
        rebufferKind: MediaFrameKind,
        at instant: ContinuousClock.Instant
    ) {
        self.rebufferKind = rebufferKind
        hasPlaybackStartEmitted = false
        isRebuffering = false
        playbackRequestedAt = instant
        timeToFirst = TimeToFirstPlaybackState()
        stalls = PerMediaKind { TrackStallState() }
        switches = PerMediaKind { TrackSwitchState() }
    }

    mutating func reset() {
        self = PlaybackLifecycleState()
    }

    mutating func closeOutInFlightStalls(at instant: ContinuousClock.Instant) {
        stalls.audio.end(at: instant)
        stalls.audio.active = false
        stalls.video.end(at: instant)
        stalls.video.active = false
        isRebuffering = false
    }

    mutating func recordSubscribeStart(
        kind: MediaFrameKind,
        trackName: String,
        trackEpoch: TrackEpoch,
        at instant: ContinuousClock.Instant
    ) {
        guard trackEpoch > 1 else { return }
        switches.update(kind) { state in
            state.start(trackName: trackName, at: instant)
        }
    }

    mutating func recordSubscribeError(
        kind: MediaFrameKind,
        message: String,
        trackEpoch: TrackEpoch
    ) {
        guard trackEpoch > 1 else { return }
        switches.update(kind) { state in
            state.markError(message)
        }
    }

    mutating func recordTrackReady(
        kind: MediaFrameKind,
        trackEpoch: TrackEpoch,
        at instant: ContinuousClock.Instant
    ) {
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
            switches.update(kind) { state in
                state.markReady(at: instant)
            }
        }
    }

    mutating func recordTrackSwitch(
        kind: MediaFrameKind,
        at instant: ContinuousClock.Instant
    ) {
        switches.update(kind) { state in
            state.markActive(at: instant)
        }
    }

    mutating func recordStall(
        kind: MediaFrameKind,
        stalled: Bool,
        at instant: ContinuousClock.Instant
    ) -> PlaybackStallChange? {
        guard stalls[kind].active != stalled else { return nil }

        stalls.update(kind) { state in
            state.active = stalled
            stalled ? state.start(at: instant) : state.end(at: instant)
        }

        var rebufferChanged = false
        if kind == rebufferKind, isRebuffering != stalled {
            isRebuffering = stalled
            rebufferChanged = true
        }

        return PlaybackStallChange(
            kind: kind,
            stalled: stalled,
            rebufferChanged: rebufferChanged
        )
    }

    /// First playback of the session (epoch 1). Records TTFF and seeds stall stats.
    /// Returns true iff the caller should emit `.playbackStart`.
    mutating func recordFirstPlay(
        context: PlaybackStartContext,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        if let requestedAt = playbackRequestedAt {
            let duration = requestedAt.duration(to: instant)
            switch context.kind {
            case .audio:
                if timeToFirst.audioPlaying == nil { timeToFirst.audioPlaying = duration }
            case .video:
                if timeToFirst.videoPlaying == nil { timeToFirst.videoPlaying = duration }
            }
        }

        stalls.update(context.kind) { state in
            state.markReady(at: instant)
        }

        guard !hasPlaybackStartEmitted, context.kind == rebufferKind else { return false }
        hasPlaybackStartEmitted = true
        return true
    }

    /// Subsequent track switch becoming audible/visible (epoch > 1). Seeds stall stats
    /// and marks the in-flight switch as playing.
    mutating func recordSwitchPlaying(
        context: PlaybackStartContext,
        at instant: ContinuousClock.Instant
    ) {
        stalls.update(context.kind) { state in
            state.markReady(at: instant)
        }
        switches.update(context.kind) { state in
            state.markPlaying(at: instant)
        }
    }

    func snapshot(at instant: ContinuousClock.Instant) -> PlaybackLifecycleSnapshot {
        PlaybackLifecycleSnapshot(
            audioStalls: stalls.audio.stats(at: instant),
            videoStalls: stalls.video.stats(at: instant),
            timeToFirst: timeToFirst.stats(),
            audioSwitches: switches.audio.stats(),
            videoSwitches: switches.video.stats()
        )
    }
}
