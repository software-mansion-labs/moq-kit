import AVFoundation
import Foundation

// MARK: - JitterBuffer

/// Generic sorted buffer with buffering/playing states for jitter resilience.
///
/// **Not thread-safe.** All access must be serialised by the owner (e.g. `VideoRendererTrack`).
///
/// `insert(item:timestampUs:)` returns `true` when the caller should fire a data-available
/// notification: either on the buffering→playing transition, or when inserting into an
/// empty buffer that is already playing.
final class JitterBuffer<T> {
    enum State {
        case buffering
        case pending
        case playing
    }

    struct Entry {
        let timestampUs: UInt64
        var offsetUs: Int64
        let item: T
    }

    private let hostClock = CMClockGetHostTimeClock()
    private var targetBufferingUs: UInt64
    private var maxOffset: Int64
    private var entries: [Entry] = []
    private var mode: State = .buffering

    init(targetBufferingUs: UInt64) {
        self.targetBufferingUs = targetBufferingUs
        self.maxOffset = Int64.min
    }

    /// Insert an item sorted by timestamp. Returns `true` if the caller should fire
    /// a data-available notification (buffering→playing transition, or first item while playing).
    @discardableResult
    func insert(item: T, timestampUs: UInt64) -> Bool {
        let offset = Int64(timestampUs) - wallClockTimeUs()

        if offset > maxOffset {
            let diff = offset - maxOffset
            for i in entries.indices {
                entries[i].offsetUs += diff
            }
            maxOffset = offset
        }

        let wasEmpty = entries.isEmpty
        let entry = Entry(timestampUs: timestampUs, offsetUs: offset, item: item)

        let index = entries.firstIndex(where: { $0.timestampUs > timestampUs }) ?? entries.endIndex
        entries.insert(entry, at: index)

        // Transition buffering → playing when we have enough depth
        if mode == .buffering, entries.count >= 2 {
            let oldest = entries.first!.timestampUs
            let newest = entries.last!.timestampUs
            if newest - oldest >= targetBufferingUs {
                mode = .playing
                return true
            }
        }

        // Notify if inserting into empty buffer while playing
        return wasEmpty && mode == .playing
    }

    /// Dequeue the oldest entry. Returns `(nil, false)` when buffering or empty.
    /// Returns `(entry, false)` for frames that should be decoded but not displayed.
    func dequeue() -> (Entry?, Bool) {
        guard mode == .playing, !entries.isEmpty else { return (nil, false) }

        let entry = entries.removeFirst()

        let estimatedLivePts = wallClockTimeUs() + maxOffset
        let targetPlaybackPts = estimatedLivePts - Int64(targetBufferingUs)

        let playable = entry.timestampUs >= targetPlaybackPts
        return (entry, playable)
    }

    /// Peek at the oldest entry without removing it. Returns nil when empty.
    func peekFront() -> Entry? {
        entries.first
    }

    /// Update the target buffering depth.
    func updateTargetBuffering(us: UInt64) {
        targetBufferingUs = us
    }

    /// Clear all entries and reset to buffering state.
    func flush() {
        entries.removeAll()
        mode = .buffering
    }

    /// Returns the PTS of the first entry satisfying `predicate`, without removing it.
    func firstPts(where predicate: (Entry) -> Bool) -> UInt64? {
        entries.first(where: predicate)?.timestampUs
    }

    /// Unconditionally set the buffer state, bypassing normal transition logic.
    func setState(_ state: State) {
        mode = state
    }

    /// Remove the front entry unconditionally, ignoring `mode`.
    /// Returns `true` if an entry was removed.
    @discardableResult
    func discardFront() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeFirst()
        return true
    }

    var state: State { mode }

    var count: Int { entries.count }

    /// Current buffered depth in milliseconds (newest − oldest entry timestamp).
    var depthMs: Double {
        guard entries.count >= 2 else { return 0 }
        return Double(entries.last!.timestampUs - entries.first!.timestampUs) / 1000.0
    }

    private func wallClockTimeUs() -> Int64 {
        let hostTime = CMClockGetTime(hostClock)
        let wallTime = CMTimeConvertScale(
            hostTime,
            timescale: 1_000_000,
            method: .roundHalfAwayFromZero
        )
        return wallTime.value
    }
}
