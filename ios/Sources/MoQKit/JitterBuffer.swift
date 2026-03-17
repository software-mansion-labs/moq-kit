import AVFoundation
import Foundation

// MARK: - JitterBuffer

/// Generic sorted buffer with buffering/playing states for jitter resilience.
///
/// Producers call `insert(item:timestampUs:)` from any thread.
/// Consumers call `dequeue()` from the real-time audio thread or display link.
/// All access is serialized via `os_unfair_lock`.
final class JitterBuffer<T>: @unchecked Sendable {
    enum State {
        case buffering
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
    private let lock = UnfairLock()
    private var entries: [Entry] = []
    private var mode: State = .buffering
    private var onDataAvailable: (() -> Void)?

    init(targetBufferingUs: UInt64) {
        self.targetBufferingUs = targetBufferingUs
        self.maxOffset = Int64.min
    }

    /// Set a callback that fires when data becomes available for dequeue.
    /// Called when transitioning buffering → playing, or when inserting into an empty buffer while playing.
    func setOnDataAvailable(_ callback: (() -> Void)?) {
        lock.withLock { onDataAvailable = callback }
    }

    /// Insert an item sorted by timestamp. Safe to call from any thread.
    func insert(item: T, timestampUs: UInt64) {
        let notify: Bool = lock.withLock {
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

            // Sorted insert by timestampUs (ascending)
            let index =
                entries.firstIndex(where: { $0.timestampUs > timestampUs })
                ?? entries.endIndex
            entries.insert(entry, at: index)

            // Transition buffering → playing when we have enough depth
            if mode == .buffering, entries.count >= 2 {
                let oldest = entries.first!.timestampUs
                let newest = entries.last!.timestampUs

                if newest - oldest >= targetBufferingUs {
                    mode = .playing
                    return onDataAvailable != nil
                }
            }

            // Notify if inserting into empty buffer while playing
            return wasEmpty && mode == .playing && onDataAvailable != nil
        }

        if notify {
            onDataAvailable?()
        }
    }

    /// Dequeue the oldest entry. Returns nil if buffering or empty or false if samnple should
    /// be decoded but shouldn't be played.
    /// Safe to call from the real-time audio thread.
    func dequeue() -> (Entry?, Bool) {
        lock.withLock {
            guard mode == .playing, !entries.isEmpty else { return (nil, false) }

            let entry = entries.removeFirst()

            let estimatedLivePts = wallClockTimeUs() + maxOffset
            let targetPlaybackPts = estimatedLivePts - Int64(targetBufferingUs)

            let playable = entry.timestampUs >= targetPlaybackPts

            return (entry, playable)
        }
    }

    /// Update the target buffering depth. Takes effect on next buffering→playing transition
    /// and immediately affects dequeue playability decisions.
    func updateTargetBuffering(us: UInt64) {
        lock.withLock { targetBufferingUs = us }
    }

    /// Clear all entries and reset to buffering state.
    func flush() {
        lock.withLock {
            entries.removeAll()
            mode = .buffering
        }
    }

    var state: State {
        lock.withLock { mode }
    }

    var count: Int {
        lock.withLock { entries.count }
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

// MARK: - UnfairLock

/// Minimal os_unfair_lock wrapper for use in JitterBuffer (real-time safe).
private final class UnfairLock: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    func withLock<R>(_ body: () -> R) -> R {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return body()
    }
}
