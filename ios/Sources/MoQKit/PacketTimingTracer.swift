import Foundation

/// Tracks wall-clock intervals between packet enqueues to detect stalls, bursts, and OOO timestamps.
/// Also measures end-to-end latency by comparing wall-clock progression against PTS progression.
final class PacketTimingTracer: @unchecked Sendable {
    enum TrackKind: String { case video, audio }

    private let kind: TrackKind
    private let stallFactor: Double
    private let burstFactor: Double
    private let reportInterval: Int
    private let reportCallback: (String) -> Void
    private let lock = NSLock()

    // Packet timing stats
    private var lastWallNs: UInt64?
    private var lastPtsUs: UInt64?
    private var highestPtsUs: UInt64?

    private var packetCount: Int = 0
    private var wallIntervalSumMs: Double = 0
    private var ptsIntervalSumMs: Double = 0
    private var intervalCount: Int = 0
    private var stallCount: Int = 0
    private var burstCount: Int = 0
    private var outOfOrderCount: Int = 0
    private var maxGapMs: Double = 0
    private var minGapMs: Double = .greatestFiniteMagnitude
    private var maxOooDeltaMs: Double = 0

    // Latency tracking (absorbed from LatencyTracker)
    private var baseWallNs: UInt64?
    private var basePtsUs: UInt64?
    private var maxOffset: Int64 = .min
    private var currentLatencyMs: Double = 0

    init(
        kind: TrackKind,
        stallFactor: Double = 2.0,
        burstFactor: Double = 0.3,
        reportInterval: Int = 120,
        reportCallback: @escaping (String) -> Void
    ) {
        self.kind = kind
        self.stallFactor = stallFactor
        self.burstFactor = burstFactor
        self.reportInterval = reportInterval
        self.reportCallback = reportCallback
    }

    /// Current end-to-end latency in milliseconds.
    var latencyMs: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentLatencyMs
    }

    /// Record a packet arrival, updating both timing diagnostics and latency measurement.
    func record(ptsUs: UInt64) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()

        // --- Latency calibration (burst-aware anchor) ---
        let wallUs = Int64(nowNs / 1000)
        let offset = Int64(ptsUs) - wallUs
        if offset > maxOffset {
            maxOffset = offset
            baseWallNs = nowNs
            basePtsUs = ptsUs
            currentLatencyMs = 0
        } else if let baseWall = baseWallNs, let basePts = basePtsUs {
            let wallElapsedMs = Double(nowNs - baseWall) / 1_000_000.0
            let ptsElapsedMs = Double(Int64(ptsUs) - Int64(basePts)) / 1000.0
            currentLatencyMs = wallElapsedMs - ptsElapsedMs
        }

        // --- Packet timing diagnostics ---
        if let highest = highestPtsUs, ptsUs < highest {
            outOfOrderCount += 1
            let deltaMs = Double(highest - ptsUs) / 1000.0
            maxOooDeltaMs = max(maxOooDeltaMs, deltaMs)
        }
        highestPtsUs = max(highestPtsUs ?? 0, ptsUs)

        if let prevWallNs = lastWallNs, let prevPtsUs = lastPtsUs {
            let wallDeltaMs = Double(nowNs - prevWallNs) / 1_000_000.0
            let isOoo = ptsUs < prevPtsUs
            let ptsDeltaMs = isOoo ? 0.0 : Double(ptsUs - prevPtsUs) / 1000.0
            let isDiscontinuity = ptsDeltaMs > 2000.0

            if !isOoo && !isDiscontinuity {
                wallIntervalSumMs += wallDeltaMs
                ptsIntervalSumMs += ptsDeltaMs
                intervalCount += 1
                maxGapMs = max(maxGapMs, wallDeltaMs)
                minGapMs = min(minGapMs, wallDeltaMs)

                if ptsDeltaMs > 0 {
                    if wallDeltaMs > ptsDeltaMs * stallFactor {
                        stallCount += 1
                    } else if wallDeltaMs < ptsDeltaMs * burstFactor {
                        burstCount += 1
                    }
                }
            }
        }

        lastWallNs = nowNs
        lastPtsUs = ptsUs
        packetCount += 1

        let shouldReport = packetCount >= reportInterval
        let snapshot: (Int, Double, Double, Int, Int, Int, Double, Double, Double)?
        if shouldReport {
            let minG = minGapMs == .greatestFiniteMagnitude ? 0.0 : minGapMs
            snapshot = (
                packetCount,
                intervalCount > 0 ? wallIntervalSumMs / Double(intervalCount) : 0,
                intervalCount > 0 ? ptsIntervalSumMs / Double(intervalCount) : 0,
                stallCount, burstCount, outOfOrderCount,
                maxOooDeltaMs, minG, maxGapMs
            )
            packetCount = 0
            wallIntervalSumMs = 0
            ptsIntervalSumMs = 0
            intervalCount = 0
            stallCount = 0
            burstCount = 0
            outOfOrderCount = 0
            maxOooDeltaMs = 0
            maxGapMs = 0
            minGapMs = .greatestFiniteMagnitude
        } else {
            snapshot = nil
        }

        lock.unlock()

        if let (pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG) = snapshot {
            let msg = String(
                format:
                    "[%@] %d pkts | avg wall %.1fms avg pts %.1fms | stalls: %d bursts: %d | ooo: %d (max -%.1fms) | gap [%.1f, %.1f]ms",
                kind.rawValue, pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG
            )
            self.reportCallback(msg)
        }
    }

    /// Reset all timing stats and latency anchor.
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        // Timing stats
        lastWallNs = nil
        lastPtsUs = nil
        highestPtsUs = nil
        packetCount = 0
        wallIntervalSumMs = 0
        ptsIntervalSumMs = 0
        intervalCount = 0
        stallCount = 0
        burstCount = 0
        outOfOrderCount = 0
        maxGapMs = 0
        minGapMs = .greatestFiniteMagnitude
        maxOooDeltaMs = 0

        // Latency anchor
        baseWallNs = nil
        basePtsUs = nil
        maxOffset = .min
        currentLatencyMs = 0
    }
}
