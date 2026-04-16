import CoreMedia

/// A thread-safe clock that converts presentation timestamps to microseconds
/// relative to the first frame received across all tracks.
///
/// All tracks in a ``MoQPublisher`` share the same `MoQClock` instance so that
/// audio and video timestamps are aligned to a common epoch.
final class MoQClock: @unchecked Sendable {
    private var epoch: CMTime?
    private let lock = UnfairLock()

    /// Convert a presentation timestamp to microseconds relative to stream start.
    ///
    /// The first call establishes the epoch and returns `0`. Subsequent calls
    /// return the offset from that epoch.
    func timestampUs(from pts: CMTime) -> UInt64 {
        lock.withLock {
            guard let epoch else {
                self.epoch = pts
                return 0
            }
            let delta = CMTimeSubtract(pts, epoch)
            let us = CMTimeConvertScale(delta, timescale: 1_000_000, method: .default)
            return UInt64(max(0, us.value))
        }
    }

    /// Reset the clock for restarting a broadcast.
    func reset() {
        lock.withLock {
            epoch = nil
        }
    }
}
