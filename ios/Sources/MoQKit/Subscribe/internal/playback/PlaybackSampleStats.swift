import Foundation

private let playbackStatsWindow: Duration = .seconds(1)
private let playbackStatsMinWindowSpan: Duration = .milliseconds(100)
private let playbackStatsArrivalGapFactor: Double = 2.0
private let playbackStatsBurstFactor: Double = 0.3
private let playbackStatsDiscontinuityThreshold: Duration = .seconds(2)

struct PlaybackSampleStatsSnapshot: Sendable {
    let audioBitrateKbps: Double?
    let videoBitrateKbps: Double?
    let videoFps: Double?
    let audioFramesDropped: UInt64?
    let videoFramesDropped: UInt64?
    let audioArrival: FrameArrivalStats?
    let videoArrival: FrameArrivalStats?
}

struct PlaybackSampleStats {
    private struct RollingTimestampWindow: Sendable {
        var entries: [UInt64] = []

        mutating func append(_ timestampNs: UInt64) {
            entries.append(timestampNs)
            prune(now: timestampNs)
        }

        mutating func prune(now: UInt64) {
            let window = playbackStatsWindow.nanosecondsUInt64Clamped
            let cutoff = now >= window ? now - window : 0
            while let first = entries.first, first < cutoff {
                entries.removeFirst()
            }
        }

        func framesPerSecond(now: UInt64) -> Double? {
            guard entries.count >= 2, let first = entries.first else { return nil }
            guard let spanNs = elapsedNs(from: first, to: now) else { return nil }
            let span = Duration.nanosecondsClamped(spanNs)
            guard span > playbackStatsMinWindowSpan else { return nil }
            let spanSec = span.milliseconds / 1_000.0
            return Double(entries.count) / spanSec
        }
    }

    private struct RollingByteWindow: Sendable {
        var entries: [(ns: UInt64, bytes: Int)] = []
        var total: Int = 0

        mutating func record(bytes: Int, now: UInt64) {
            entries.append((ns: now, bytes: bytes))
            total += bytes
            prune(now: now)
        }

        mutating func prune(now: UInt64) {
            let window = playbackStatsWindow.nanosecondsUInt64Clamped
            let cutoff = now >= window ? now - window : 0
            while let first = entries.first, first.ns < cutoff {
                total -= first.bytes
                entries.removeFirst()
            }
        }

        func bitrateKbps(now: UInt64) -> Double? {
            guard let first = entries.first else { return nil }
            guard let spanNs = elapsedNs(from: first.ns, to: now) else { return nil }
            let span = Duration.nanosecondsClamped(spanNs)
            guard span > playbackStatsMinWindowSpan else { return nil }
            let spanSec = span.milliseconds / 1_000.0
            return Double(total) * 8.0 / 1000.0 / spanSec
        }
    }

    private struct RollingDurationWindow: Sendable {
        var entries: [(ns: UInt64, duration: Duration)] = []
        var total: Duration = .zero

        var average: Duration? {
            entries.isEmpty ? nil : total / entries.count
        }

        var maxDuration: Duration? {
            entries.map(\.duration).max()
        }

        mutating func append(duration: Duration, now: UInt64) {
            entries.append((ns: now, duration: duration))
            total += duration
            prune(now: now)
        }

        mutating func prune(now: UInt64) {
            let window = playbackStatsWindow.nanosecondsUInt64Clamped
            let cutoff = now >= window ? now - window : 0
            while let first = entries.first, first.ns < cutoff {
                total -= first.duration
                entries.removeFirst()
            }
        }
    }

    private struct FrameArrivalState: Sendable {
        var lastWallNs: UInt64?
        var lastPtsUs: UInt64?
        var highestPtsUs: UInt64?

        var frameTimestamps = RollingTimestampWindow()
        var intervals = RollingDurationWindow()

        var slowArrivalCount: UInt64 = 0
        var fastArrivalCount: UInt64 = 0
        var outOfOrderCount: UInt64 = 0
        var maxOutOfOrderDelta: Duration?
        var discontinuityCount: UInt64 = 0
        var maxDiscontinuityGap: Duration?

        var hasData: Bool {
            !frameTimestamps.entries.isEmpty || slowArrivalCount > 0 || fastArrivalCount > 0
                || outOfOrderCount > 0 || discontinuityCount > 0
        }

        mutating func resetTimingBaseline() {
            lastWallNs = nil
            lastPtsUs = nil
            highestPtsUs = nil
        }
    }

    private var byteWindows = PerMediaKind { RollingByteWindow() }
    private var arrivals = PerMediaKind { FrameArrivalState() }
    private var framesDropped = PerMediaKind(audio: UInt64.zero, video: UInt64.zero)
    private var videoFrameTimestamps = RollingTimestampWindow()

    mutating func reset() {
        self = PlaybackSampleStats()
    }

    mutating func recordVideoFrameDisplayed(now: UInt64) {
        videoFrameTimestamps.append(now)
    }

    mutating func recordVideoFrameDropped() {
        framesDropped.video += 1
    }

    mutating func recordAudioFramesDropped(_ count: Int) {
        guard count > 0 else { return }
        framesDropped.audio += UInt64(count)
    }

    mutating func onMediaTrackStarted(kind: MediaFrameKind) {
        arrivals.update(kind) { state in
            state.resetTimingBaseline()
        }
    }

    mutating func onMediaFrame(
        kind: MediaFrameKind,
        frame: MediaFrame,
        now: UInt64
    ) {
        byteWindows.update(kind) { window in
            window.record(bytes: frame.payload.count, now: now)
        }
        arrivals.update(kind) { state in
            Self.recordArrival(frame: frame, now: now, state: &state)
        }
    }

    mutating func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        let gap = Duration.microsecondsClamped(gapUs)
        arrivals.update(kind) { state in
            state.discontinuityCount += 1
            state.maxDiscontinuityGap = maxDuration(state.maxDiscontinuityGap, gap)
            state.resetTimingBaseline()
        }
    }

    func snapshot(now: UInt64) -> PlaybackSampleStatsSnapshot {
        PlaybackSampleStatsSnapshot(
            audioBitrateKbps: byteWindows.audio.bitrateKbps(now: now),
            videoBitrateKbps: byteWindows.video.bitrateKbps(now: now),
            videoFps: videoFrameTimestamps.framesPerSecond(now: now),
            audioFramesDropped: framesDropped.audio > 0 ? framesDropped.audio : nil,
            videoFramesDropped: framesDropped.video > 0 ? framesDropped.video : nil,
            audioArrival: makeFrameArrivalStats(arrivals.audio, now: now),
            videoArrival: makeFrameArrivalStats(arrivals.video, now: now)
        )
    }

    private static func recordArrival(
        frame: MediaFrame,
        now: UInt64,
        state: inout FrameArrivalState
    ) {
        state.frameTimestamps.append(now)
        state.intervals.prune(now: now)

        if let highest = state.highestPtsUs, frame.timestampUs < highest {
            state.outOfOrderCount += 1
            let delta = Duration.microsecondsClamped(highest - frame.timestampUs)
            state.maxOutOfOrderDelta = maxDuration(state.maxOutOfOrderDelta, delta)
        }
        state.highestPtsUs = max(state.highestPtsUs ?? 0, frame.timestampUs)

        if let previousWallNs = state.lastWallNs, let previousPtsUs = state.lastPtsUs {
            let isOutOfOrder = frame.timestampUs < previousPtsUs
            let ptsDeltaUs = isOutOfOrder ? 0 : frame.timestampUs - previousPtsUs

            let ptsDelta = Duration.microsecondsClamped(ptsDeltaUs)
            if !isOutOfOrder,
                ptsDelta <= playbackStatsDiscontinuityThreshold,
                let wallDeltaNs = elapsedNs(from: previousWallNs, to: now)
            {
                let wallDelta = Duration.nanosecondsClamped(wallDeltaNs)
                state.intervals.append(duration: wallDelta, now: now)

                let ptsDeltaMs = ptsDelta.milliseconds
                if ptsDeltaMs > 0 {
                    let wallDeltaMs = wallDelta.milliseconds
                    if wallDeltaMs > ptsDeltaMs * playbackStatsArrivalGapFactor {
                        state.slowArrivalCount += 1
                    } else if wallDeltaMs < ptsDeltaMs * playbackStatsBurstFactor {
                        state.fastArrivalCount += 1
                    }
                }
            }
        }

        state.lastWallNs = now
        state.lastPtsUs = frame.timestampUs
    }

    private func makeFrameArrivalStats(
        _ state: FrameArrivalState,
        now: UInt64
    ) -> FrameArrivalStats? {
        guard state.hasData else { return nil }

        return FrameArrivalStats(
            receivedFramesPerSecond: state.frameTimestamps.framesPerSecond(now: now),
            averageInterarrival: state.intervals.average,
            maxInterarrival: state.intervals.maxDuration,
            slowArrivalCount: state.slowArrivalCount,
            fastArrivalCount: state.fastArrivalCount,
            outOfOrderCount: state.outOfOrderCount,
            maxOutOfOrderDelta: state.maxOutOfOrderDelta,
            discontinuityCount: state.discontinuityCount,
            maxDiscontinuityGap: state.maxDiscontinuityGap
        )
    }
}

private func maxDuration(_ lhs: Duration?, _ rhs: Duration) -> Duration {
    guard let lhs else { return rhs }
    return max(lhs, rhs)
}

private func elapsedNs(from start: UInt64, to end: UInt64) -> UInt64? {
    let elapsed = end.subtractingReportingOverflow(start)
    return elapsed.overflow ? nil : elapsed.partialValue
}
