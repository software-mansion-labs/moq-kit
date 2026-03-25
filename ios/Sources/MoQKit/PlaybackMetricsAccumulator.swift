import Foundation

/// Thread-safe accumulator for playback quality metrics.
///
/// All write methods are real-time safe (no allocation, `os_unfair_lock` only).
/// One `snapshot()` method reads all fields under the lock and returns `PlaybackStats`.
final class PlaybackMetricsAccumulator: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>

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

    // Bitrate — audio (1-sec rolling window)
    private var audioBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var audioBytesTotal: Int = 0

    // Bitrate — video (1-sec rolling window)
    private var videoBytesWindow: [(ns: UInt64, bytes: Int)] = []
    private var videoBytesTotal: Int = 0

    // FPS — video (1-sec rolling window)
    private var videoFrameTimestamps: [UInt64] = []

    // Dropped frames
    private var audioFramesDropped: UInt64 = 0
    private var videoFramesDropped: UInt64 = 0

    private static let windowNs: UInt64 = 1_000_000_000 // 1 second

    init() {
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - TTFF

    func markPlayStart() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        playStartNs = now
        os_unfair_lock_unlock(lock)
    }

    func markFirstAudioFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        if firstAudioFrameNs == 0 {
            firstAudioFrameNs = now
        }
        os_unfair_lock_unlock(lock)
    }

    func markFirstVideoFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        if firstVideoFrameNs == 0 {
            firstVideoFrameNs = now
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Stalls

    func audioStallBegan() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        if !audioIsStalled {
            audioIsStalled = true
            audioStallCount += 1
            audioStallStartNs = now
            // Accumulate play time up to now
            if audioIsPlaying {
                audioPlayTimeNs += now - audioPlayStartNs
                audioIsPlaying = false
            }
        }
        os_unfair_lock_unlock(lock)
    }

    func audioStallEnded() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        if audioIsStalled {
            audioIsStalled = false
            audioStallTotalNs += now - audioStallStartNs
            // Resume play time tracking
            audioIsPlaying = true
            audioPlayStartNs = now
        } else if !audioIsPlaying {
            // First time playing (no prior stall)
            audioIsPlaying = true
            audioPlayStartNs = now
        }
        os_unfair_lock_unlock(lock)
    }

    func videoStallBegan() {
        let now = DispatchTime.now().uptimeNanoseconds
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
        let now = DispatchTime.now().uptimeNanoseconds
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

    // MARK: - Bitrate

    func recordAudioBytes(_ count: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        audioBytesWindow.append((ns: now, bytes: count))
        audioBytesTotal += count
        pruneWindow(entries: &audioBytesWindow, total: &audioBytesTotal, now: now)
        os_unfair_lock_unlock(lock)
    }

    func recordVideoBytes(_ count: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)
        videoBytesWindow.append((ns: now, bytes: count))
        videoBytesTotal += count
        pruneWindow(entries: &videoBytesWindow, total: &videoBytesTotal, now: now)
        os_unfair_lock_unlock(lock)
    }

    // MARK: - FPS

    func recordVideoFrameDisplayed() {
        let now = DispatchTime.now().uptimeNanoseconds
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
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock)

        // TTFF — guard against UInt64 underflow if a frame callback fires before
        // markPlayStart() (e.g. immediately after reset() during pause/play).
        let ttfAudio: Double? = (playStartNs > 0 && firstAudioFrameNs >= playStartNs)
            ? Double(firstAudioFrameNs - playStartNs) / 1_000_000.0 : nil
        let ttfVideo: Double? = (playStartNs > 0 && firstVideoFrameNs >= playStartNs)
            ? Double(firstVideoFrameNs - playStartNs) / 1_000_000.0 : nil

        // Audio stalls
        let aStalls: StallStats? = audioStallCount > 0 || audioIsPlaying || audioIsStalled
            ? makeStallStats(
                count: audioStallCount, stallTotalNs: audioStallTotalNs,
                isStalled: audioIsStalled, stallStartNs: audioStallStartNs,
                playTimeNs: audioPlayTimeNs, isPlaying: audioIsPlaying,
                playStartNs: audioPlayStartNs, now: now)
            : nil

        // Video stalls
        let vStalls: StallStats? = videoStallCount > 0 || videoIsPlaying || videoIsStalled
            ? makeStallStats(
                count: videoStallCount, stallTotalNs: videoStallTotalNs,
                isStalled: videoIsStalled, stallStartNs: videoStallStartNs,
                playTimeNs: videoPlayTimeNs, isPlaying: videoIsPlaying,
                playStartNs: videoPlayStartNs, now: now)
            : nil

        // Bitrate
        let aBitrate = computeBitrateKbps(entries: audioBytesWindow, total: audioBytesTotal, now: now)
        let vBitrate = computeBitrateKbps(entries: videoBytesWindow, total: videoBytesTotal, now: now)

        // FPS
        let fps = computeFps(entries: videoFrameTimestamps, now: now)

        // Dropped
        let aDrop = audioFramesDropped
        let vDrop = videoFramesDropped

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
            videoJitterBufferMs: videoJitterBufferMs
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

        audioFramesDropped = 0
        videoFramesDropped = 0
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Private helpers (called under lock)

    private func pruneWindow(entries: inout [(ns: UInt64, bytes: Int)], total: inout Int, now: UInt64) {
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

    private func computeBitrateKbps(entries: [(ns: UInt64, bytes: Int)], total: Int, now: UInt64) -> Double? {
        guard let first = entries.first else { return nil }
        let spanNs = now - first.ns
        guard spanNs > 100_000_000 else { return nil } // need at least 100ms of data
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(total) * 8.0 / 1000.0 / spanSec
    }

    private func computeFps(entries: [UInt64], now: UInt64) -> Double? {
        guard entries.count >= 2, let first = entries.first else { return nil }
        let spanNs = now - first
        guard spanNs > 100_000_000 else { return nil }
        let spanSec = Double(spanNs) / 1_000_000_000.0
        return Double(entries.count) / spanSec
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
