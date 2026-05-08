import Foundation

/// Tracks the estimated live edge for one media stream from compressed-frame arrivals.
final class MediaLiveEdge: @unchecked Sendable {
    private let lock = NSLock()
    private let wallClock: any PlaybackWallClock
    private var maxOffset: Int64?

    convenience init() {
        self.init(wallClock: HostPlaybackWallClock())
    }

    init(wallClock: any PlaybackWallClock) {
        self.wallClock = wallClock
    }

    func recordTimestamp(_ timestamp: UInt64) {
        guard let signedTimestamp = Self.signedTimestamp(timestamp) else { return }
        let result = signedTimestamp.subtractingReportingOverflow(wallClock.now(in: .us))
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
        let result = wallClock.now(in: .us).addingReportingOverflow(offset)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    private static func signedTimestamp(_ timestamp: UInt64) -> Int64? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return Int64(timestamp)
    }
}
