import Foundation

// MARK: - UnfairLock

/// Minimal `os_unfair_lock` wrapper. Real-time safe; no priority inversion.
class UnfairLock: @unchecked Sendable {
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
