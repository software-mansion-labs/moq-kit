import CoreMedia
import Foundation

/// Tracks the estimated live edge for one media stream from compressed-frame arrivals.
final class MediaLiveEdge: @unchecked Sendable {
    private let lock = NSLock()
    private let wallClockProvider: @Sendable () -> Int64
    private var maxOffset: Int64?

    convenience init() {
        let hostClock = CMClockGetHostTimeClock()
        self.init {
            let hostTime = CMClockGetTime(hostClock)
            let wallTime = CMTimeConvertScale(
                hostTime,
                timescale: 1_000_000,
                method: .roundHalfAwayFromZero
            )
            return wallTime.value
        }
    }

    init(wallClockProvider: @escaping @Sendable () -> Int64) {
        self.wallClockProvider = wallClockProvider
    }

    func recordTimestamp(_ timestamp: UInt64) {
        guard let signedTimestamp = Self.signedTimestamp(timestamp) else { return }
        let result = signedTimestamp.subtractingReportingOverflow(wallClockProvider())
        guard !result.overflow else { return }
        let offset = result.partialValue

        lock.lock()
        maxOffset = max(maxOffset ?? Int64.min, offset)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        maxOffset = nil
        lock.unlock()
    }

    func estimatedLivePTS() -> Int64? {
        lock.lock()
        let offset = maxOffset
        lock.unlock()

        guard let offset else { return nil }
        let result = wallClockProvider().addingReportingOverflow(offset)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    private static func signedTimestamp(_ timestamp: UInt64) -> Int64? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return Int64(timestamp)
    }
}
