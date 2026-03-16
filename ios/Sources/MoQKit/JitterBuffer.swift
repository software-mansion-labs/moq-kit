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
        let item: T
    }

    private let targetBufferingUs: UInt64
    private let lock = UnfairLock()
    private var entries: [Entry] = []
    private var mode: State = .buffering

    init(targetBufferingUs: UInt64) {
        self.targetBufferingUs = targetBufferingUs
    }

    /// Insert an item sorted by timestamp. Safe to call from any thread.
    func insert(item: T, timestampUs: UInt64) {
        lock.withLock {
            let entry = Entry(timestampUs: timestampUs, item: item)

            // Sorted insert by timestampUs (ascending)
            let index = entries.firstIndex(where: { $0.timestampUs > timestampUs })
                ?? entries.endIndex
            entries.insert(entry, at: index)

            // Transition buffering → playing when we have enough depth
            if mode == .buffering, entries.count >= 2 {
                let oldest = entries.first!.timestampUs
                let newest = entries.last!.timestampUs
                if newest - oldest >= targetBufferingUs {
                    print("set to playing, we have \(newest - oldest) delay, buffers = \(entries.count), mode = \(mode)")
                    mode = .playing
                }
            }
        }
    }

    /// Dequeue the oldest entry. Returns nil if buffering or empty.
    /// Safe to call from the real-time audio thread.
    func dequeue() -> Entry? {
        lock.withLock {
            guard mode == .playing, !entries.isEmpty else { return nil }

            return entries.removeFirst()
        }
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
