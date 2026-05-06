import Foundation

/// Tracks wall-clock intervals between packet arrivals to detect stalls, bursts, and OOO timestamps.
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

    /// Record a packet arrival, updating timing diagnostics.
    func record(ptsUs: UInt64) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()

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

        if packetCount >= reportInterval {
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
        }

        lock.unlock()
    }

    /// Reset all timing stats.
    func reset() {
        lock.lock()
        defer { lock.unlock() }

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
    }
}
