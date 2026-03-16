import Foundation

// MARK: - BaseTimestamp

/// Thread-safe container for the first frame timestamp, shared between video and audio tasks.
final class BaseTimestamp: @unchecked Sendable {
    private var value: UInt64?
    private let lock = NSLock()

    func resolve(_ timestampUs: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let v = value { return v }
        value = timestampUs
        return timestampUs
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

// MARK: - LatencyTracker

/// Measures end-to-end latency by comparing wall-clock progression against PTS progression.
final class LatencyTracker: @unchecked Sendable {
    private var baseWallNs: UInt64?
    private var basePtsUs: UInt64?
    private var currentLatencyMs: Double = 0
    private let lock = NSLock()

    func calibrate(ptsUs: UInt64) {
        let wallNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard baseWallNs == nil else { return }
        baseWallNs = wallNs
        basePtsUs = ptsUs
        currentLatencyMs = 0
    }

    func record(ptsUs: UInt64) {
        let wallNs = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard let baseWall = baseWallNs, let basePts = basePtsUs else { return }
        let wallElapsedMs = Double(wallNs - baseWall) / 1_000_000.0
        let ptsElapsedMs = Double(ptsUs - basePts) / 1000.0
        currentLatencyMs = wallElapsedMs - ptsElapsedMs
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        baseWallNs = nil
        basePtsUs = nil
        currentLatencyMs = 0
    }

    var latencyMs: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentLatencyMs
    }
}
