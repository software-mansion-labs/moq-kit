import Foundation

/// Thread-safe tracker for playback quality metrics and received-frame diagnostics.
///
/// Write methods are safe to call from playback ingest, render, and audio callback threads.
/// `snapshot()` reads all tracked fields under the lock and returns `PlaybackStats`.
final class PlaybackStatsTracker: MediaFrameObserver, @unchecked Sendable {
    private struct FrameArrivalState {
        var lastWallNs: UInt64?
        var lastPtsUs: UInt64?
        var highestPtsUs: UInt64?

        var frameTimestamps: [UInt64] = []
        var intervalsWindow: [(ns: UInt64, ms: Double)] = []
        var intervalMsTotal: Double = 0

        var arrivalGapCount: UInt64 = 0
        var burstCount: UInt64 = 0
        var outOfOrderCount: UInt64 = 0
        var maxOutOfOrderDeltaMs: Double = 0
        var discontinuityCount: UInt64 = 0
        var maxDiscontinuityGapMs: Double = 0

        var hasData: Bool {
            !frameTimestamps.isEmpty || arrivalGapCount > 0 || burstCount > 0
                || outOfOrderCount > 0 || discontinuityCount > 0
        }

        mutating func resetAll() {
            lastWallNs = nil
            lastPtsUs = nil
            highestPtsUs = nil
            frameTimestamps.removeAll()
            intervalsWindow.removeAll()
            intervalMsTotal = 0
            arrivalGapCount = 0
            burstCount = 0
            outOfOrderCount = 0
            maxOutOfOrderDeltaMs = 0
            discontinuityCount = 0
            maxDiscontinuityGapMs = 0
        }

        mutating func resetTimingBaseline() {
            lastWallNs = nil
            lastPtsUs = nil
            highestPtsUs = nil
        }
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let clock: @Sendable () -> UInt64

    // TTFF
    private var playStartNs: UInt64 = 0
    private var firstAudioFrameNs: UInt64 = 0
    private var firstVideoFrameNs: UInt64 = 0

    // Stalls — audio
    private var audioStallCount: UInt64 = 0
    private var audioStallStartNs: UInt64 = 0
    private var audioStallTotalNs: UInt64 = 0
    private var audioIsStalled: Bool = false
    private var audioPlayTimeNs: UInt64 = 0
    private var audioPlayStartNs: UInt64 = 0
    private var audioIsPlaying: Bool = false

    // Stalls — video
    private var videoStallCount: UInt64 = 0
    private var videoStallStartNs: UInt64 = 0
    private var videoStallTotalNs: UInt64 = 0
    private var videoIsStalled: Bool = false
    private var videoPlayTimeNs: UInt64 = 0
    private var videoPlayStartNs: UInt64 = 0
    private var videoIsPlaying: Bool = false

    // Bitrate — audio/video (1-sec rolling window)
    private var audioBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var audioBytesTotal: Int = 0
    private var videoBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var videoBytesTotal: Int = 0

    // FPS — displayed video (1-sec rolling window)
    private var videoFrameTimestamps: [UInt64] = []

    // Received-frame arrival diagnostics
    private var audioArrival = FrameArrivalState()
    private var videoArrival = FrameArrivalState()

    // Dropped frames
    private var audioFramesDropped: UInt64 = 0
    private var videoFramesDropped: UInt64 = 0

    private static let windowNs: UInt64 = 1_000_000_000
    private static let minWindowSpanNs: UInt64 = 100_000_000
    private static let arrivalGapFactor: Double = 2.0
    private static let burstFactor: Double = 0.3
    private static let discontinuityThresholdUs: UInt64 = 2_000_000

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - MediaFrameObserver

    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind) {
        let now = clock()

        os_unfair_lock_lock(lock)
        switch kind {
        case .audio:
            if firstAudioFrameNs == 0 {
                firstAudioFrameNs = now
            }
            audioBytesWindow.append((ns: now, bytes: frame.payload.count))
            audioBytesTotal += frame.payload.count
            pruneWindow(entries: &audioBytesWindow, total: &audioBytesTotal, now: now)
            recordArrival(frame: frame, now: now, state: &audioArrival)

        case .video:
            if firstVideoFrameNs == 0 {
                firstVideoFrameNs = now
            }
            videoBytesWindow.append((ns: now, bytes: frame.payload.count))
            videoBytesTotal += frame.payload.count
            pruneWindow(entries: &videoBytesWindow, total: &videoBytesTotal, now: now)
            recordArrival(frame: frame, now: now, state: &videoArrival)
        }
        os_unfair_lock_unlock(lock)
    }

    func onFrameDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        os_unfair_lock_lock(lock)
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
        os_unfair_lock_unlock(lock)
    }

    // MARK: - TTFF

    func markPlayStart() {
        let now = clock()
        os_unfair_lock_lock(lock)
        playStartNs = now
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Stalls

    func audioStallBegan() {
        let now = clock()
        os_unfair_lock_lock(lock)
        if !audioIsStalled {
            audioIsStalled = true
            audioStallCount += 1
            audioStallStartNs = now
            if audioIsPlaying {
                audioPlayTimeNs += now - audioPlayStartNs
                audioIsPlaying = false
            }
        }
        os_unfair_lock_unlock(lock)
    }

    func audioStallEnded() {
        let now = clock()
        os_unfair_lock_lock(lock)
        if audioIsStalled {
            audioIsStalled = false
            audioStallTotalNs += now - audioStallStartNs
            audioIsPlaying = true
            audioPlayStartNs = now
        } else if !audioIsPlaying {
            audioIsPlaying = true
            audioPlayStartNs = now
        }
        os_unfair_lock_unlock(lock)
    }

    func videoStallBegan() {
        let now = clock()
        os_unfair_lock_lock(lock)
        if !videoIsStalled {
            videoIsStalled = true
            videoStallCount += 1
            videoStallStartNs = now
            if videoIsPlaying {
                videoPlayTimeNs += now - videoPlayStartNs
                videoIsPlaying = false
            }
        }
        os_unfair_lock_unlock(lock)
    }

    func videoStallEnded() {
        let now = clock()
        os_unfair_lock_lock(lock)
        if videoIsStalled {
            videoIsStalled = false
            videoStallTotalNs += now - videoStallStartNs
            videoIsPlaying = true
            videoPlayStartNs = now
        } else if !videoIsPlaying {
            videoIsPlaying = true
            videoPlayStartNs = now
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: - FPS

    func recordVideoFrameDisplayed() {
        let now = clock()
        os_unfair_lock_lock(lock)
        videoFrameTimestamps.append(now)
        pruneTimestamps(entries: &videoFrameTimestamps, now: now)
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Dropped frames

    func recordVideoFrameDropped() {
        os_unfair_lock_lock(lock)
        videoFramesDropped += 1
        os_unfair_lock_unlock(lock)
    }

    func recordAudioFramesDropped(_ count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        audioFramesDropped += UInt64(count)
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Snapshot

    func snapshot(
        audioLatencyMs: Double?, videoLatencyMs: Double?,
        audioRingBufferMs: Double?, videoJitterBufferMs: Double?
    ) -> PlaybackStats {
        let now = clock()
        os_unfair_lock_lock(lock)

        let ttfAudio: Double? =
            (playStartNs > 0 && firstAudioFrameNs >= playStartNs)
            ? Double(firstAudioFrameNs - playStartNs) / 1_000_000.0 : nil
        let ttfVideo: Double? =
            (playStartNs > 0 && firstVideoFrameNs >= playStartNs)
            ? Double(firstVideoFrameNs - playStartNs) / 1_000_000.0 : nil

        let aStalls: StallStats? =
            audioStallCount > 0 || audioIsPlaying || audioIsStalled
            ? makeStallStats(
                count: audioStallCount, stallTotalNs: audioStallTotalNs,
                isStalled: audioIsStalled, stallStartNs: audioStallStartNs,
                playTimeNs: audioPlayTimeNs, isPlaying: audioIsPlaying,
                playStartNs: audioPlayStartNs, now: now)
            : nil

        let vStalls: StallStats? =
            videoStallCount > 0 || videoIsPlaying || videoIsStalled
            ? makeStallStats(
                count: videoStallCount, stallTotalNs: videoStallTotalNs,
                isStalled: videoIsStalled, stallStartNs: videoStallStartNs,
                playTimeNs: videoPlayTimeNs, isPlaying: videoIsPlaying,
                playStartNs: videoPlayStartNs, now: now)
            : nil

        let aBitrate = computeBitrateKbps(
            entries: audioBytesWindow, total: audioBytesTotal, now: now)
        let vBitrate = computeBitrateKbps(
            entries: videoBytesWindow, total: videoBytesTotal, now: now)
        let fps = computeFps(entries: videoFrameTimestamps, now: now)
        let aDrop = audioFramesDropped
        let vDrop = videoFramesDropped
        let audioArrivalStats = makeFrameArrivalStats(audioArrival, now: now)
        let videoArrivalStats = makeFrameArrivalStats(videoArrival, now: now)

        os_unfair_lock_unlock(lock)

        return PlaybackStats(
            audioLatencyMs: audioLatencyMs,
            videoLatencyMs: videoLatencyMs,
            audioStalls: aStalls,
            videoStalls: vStalls,
            audioBitrateKbps: aBitrate,
            videoBitrateKbps: vBitrate,
            timeToFirstAudioFrameMs: ttfAudio,
            timeToFirstVideoFrameMs: ttfVideo,
            videoFps: fps,
            audioFramesDropped: aDrop > 0 ? aDrop : nil,
            videoFramesDropped: vDrop > 0 ? vDrop : nil,
            audioRingBufferMs: audioRingBufferMs,
            videoJitterBufferMs: videoJitterBufferMs,
            audioArrival: audioArrivalStats,
            videoArrival: videoArrivalStats
        )
    }

    // MARK: - Reset

    func reset() {
        os_unfair_lock_lock(lock)
        playStartNs = 0
        firstAudioFrameNs = 0
        firstVideoFrameNs = 0

        audioStallCount = 0
        audioStallStartNs = 0
        audioStallTotalNs = 0
        audioIsStalled = false
        audioPlayTimeNs = 0
        audioPlayStartNs = 0
        audioIsPlaying = false

        videoStallCount = 0
        videoStallStartNs = 0
        videoStallTotalNs = 0
        videoIsStalled = false
        videoPlayTimeNs = 0
        videoPlayStartNs = 0
        videoIsPlaying = false

        audioBytesWindow.removeAll()
        audioBytesTotal = 0
        videoBytesWindow.removeAll()
        videoBytesTotal = 0
        videoFrameTimestamps.removeAll()
        audioArrival.resetAll()
        videoArrival.resetAll()

        audioFramesDropped = 0
        videoFramesDropped = 0
        os_unfair_lock_unlock(lock)
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

            if !isOutOfOrder && ptsDeltaUs <= Self.discontinuityThresholdUs {
                let wallDeltaMs = Double(now - previousWallNs) / 1_000_000.0
                state.intervalsWindow.append((ns: now, ms: wallDeltaMs))
                state.intervalMsTotal += wallDeltaMs
                pruneArrivalIntervals(state: &state, now: now)

                let ptsDeltaMs = Double(ptsDeltaUs) / 1_000.0
                if ptsDeltaMs > 0 {
                    if wallDeltaMs > ptsDeltaMs * Self.arrivalGapFactor {
                        state.arrivalGapCount += 1
                    } else if wallDeltaMs < ptsDeltaMs * Self.burstFactor {
                        state.burstCount += 1
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
        let spanNs = now - first.ns
        guard spanNs > Self.minWindowSpanNs else { return nil }
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(total) * 8.0 / 1000.0 / spanSec
    }

    private func computeFps(entries: [UInt64], now: UInt64) -> Double? {
        guard entries.count >= 2, let first = entries.first else { return nil }
        let spanNs = now - first
        guard spanNs > Self.minWindowSpanNs else { return nil }
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(entries.count) / spanSec
    }

    private func makeFrameArrivalStats(_ state: FrameArrivalState, now: UInt64)
        -> FrameArrivalStats?
    {
        guard state.hasData else { return nil }
        let intervalCount = state.intervalsWindow.count
        let averageInterarrivalMs =
            intervalCount > 0 ? state.intervalMsTotal / Double(intervalCount) : nil
        let maxInterarrivalMs = state.intervalsWindow.map(\.ms).max()

        return FrameArrivalStats(
            receivedFramesPerSecond: computeFps(entries: state.frameTimestamps, now: now),
            averageInterarrivalMs: averageInterarrivalMs,
            maxInterarrivalMs: maxInterarrivalMs,
            arrivalGapCount: state.arrivalGapCount,
            burstCount: state.burstCount,
            outOfOrderCount: state.outOfOrderCount,
            maxOutOfOrderDeltaMs: state.maxOutOfOrderDeltaMs > 0
                ? state.maxOutOfOrderDeltaMs : nil,
            discontinuityCount: state.discontinuityCount,
            maxDiscontinuityGapMs: state.maxDiscontinuityGapMs > 0
                ? state.maxDiscontinuityGapMs : nil
        )
    }

    private func makeStallStats(
        count: UInt64, stallTotalNs: UInt64,
        isStalled: Bool, stallStartNs: UInt64,
        playTimeNs: UInt64, isPlaying: Bool,
        playStartNs: UInt64, now: UInt64
    ) -> StallStats {
        var totalStallNs = stallTotalNs
        if isStalled {
            totalStallNs += now - stallStartNs
        }
        var totalPlayNs = playTimeNs
        if isPlaying {
            totalPlayNs += now - playStartNs
        }
        let totalMs = Double(totalStallNs) / 1_000_000.0
        let totalTime = Double(totalPlayNs + totalStallNs)
        let ratio = totalTime > 0 ? Double(totalStallNs) / totalTime : 0
        return StallStats(count: count, totalDurationMs: totalMs, rebufferingRatio: ratio)
    }
}
