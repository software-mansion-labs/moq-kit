import Foundation

// DEBUG: maps userData pointer address → label string; intentionally never cleared (leaked)
nonisolated(unsafe) private var _debugLabels: [Int: String] = [:]

final class CallbackContext: Sendable {
    let continuation: AsyncStream<Int32>.Continuation
    fileprivate let label: String

    init(_ continuation: AsyncStream<Int32>.Continuation, label: String) {
        self.continuation = continuation
        self.label = label
    }
}

/// Owns a C callback's lifetime. Call `release()` after the associated C close function returns,
/// to guarantee the callback context outlives the C handle.
/// Safe to call `release()` multiple times; subsequent calls are no-ops.
final class CallbackLease: @unchecked Sendable {
    let stream: AsyncStream<Int32>
    let callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    let userData: UnsafeMutableRawPointer

    private let lock = NSLock()
    private var released = false

    fileprivate init(
        stream: AsyncStream<Int32>,
        callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void,
        userData: UnsafeMutableRawPointer
    ) {
        self.stream = stream
        self.callback = callback
        self.userData = userData
    }

    /// Releases the retained CallbackContext. Idempotent.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        Unmanaged<CallbackContext>.fromOpaque(userData).release()
    }

    deinit {
        release()
    }
}

func makeCallbackStream(label: String) -> CallbackLease {
    var continuation: AsyncStream<Int32>.Continuation!
    let stream = AsyncStream<Int32> { continuation = $0 }

    let context = CallbackContext(continuation, label: label)
    let userData = Unmanaged.passRetained(context).toOpaque()

    // DEBUG: stash label by address so the callback can always read it even after context is freed
    _debugLabels[Int(bitPattern: userData)] = label

    let callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ptr, value in
        let label = _debugLabels[Int(bitPattern: ptr)] ?? "<unknown:\(String(describing: ptr))>"
        print("[CallbackBridge] \(label) called with value: \(value)")
        guard let ptr else { return }
        let ctx = Unmanaged<CallbackContext>.fromOpaque(ptr).takeUnretainedValue()
        ctx.continuation.yield(value)
        print("[CallbackBridge] \(label) after yield")
    }

    return CallbackLease(stream: stream, callback: callback, userData: userData)
}

// MARK: - CallbackStreamHandle

/// Owns the full lifecycle of a C resource driven by a single callback stream.
/// Construction: calls `open(callback, userData)` → captures the returned handle.
/// Destruction: calls `close(handle)` → awaits drain task (which has processed the
///              final callback and released the lease via its own defer) → returns.
final class CallbackStreamHandle: @unchecked Sendable {
    let handle: UInt32
    private let lease: CallbackLease
    private let closeFunc: (UInt32) -> Void
    private let lock = NSLock()
    private var closed = false
    private var drainTask: Task<Void, Never>?

    /// Opens the resource. `open` receives the C callback and userData; must return a handle.
    init(
        label: String,
        open: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void,
               UnsafeMutableRawPointer) throws -> UInt32,
        close: @escaping (UInt32) -> Void,
        onEvent: @escaping (Int32) -> Void,
        onDone: @escaping () -> Void

    ) throws {
        let lease = makeCallbackStream(label: label)
        self.handle = try open(lease.callback, lease.userData)
        self.lease = lease
        self.closeFunc = close
        self.drainTask = Task {
            defer { self.lease.release() }

            for await rawId in self.lease.stream {
                if rawId < 0 { break }
                onEvent(rawId)
            }

            onDone()
        }
    }

    /// Correct close path: C close → drain task finishes (final callback processed,
    /// lease released) → returns. Idempotent.
    func close() async {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let task = drainTask
        lock.unlock()

        closeFunc(handle)
        await task?.value
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Best-effort sync path used from deinit (cannot await).
    /// Triggers C close; the still-running drain task processes the final callback
    /// and releases the lease asynchronously via its defer.
    deinit {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        closeFunc(handle)
    }
}

extension String {
    func withCStringLen<R>(_ body: (UnsafePointer<CChar>, UInt) throws -> R) rethrows -> R {
        try withCString { ptr in
            try body(ptr, UInt(utf8.count))
        }
    }
}

extension Data {
    func withUnsafeBytesLen<R>(_ body: (UnsafePointer<UInt8>, UInt) throws -> R) rethrows -> R {
        try withUnsafeBytes { raw in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer<UInt8>(bitPattern: 1)!
            return try body(ptr, UInt(count))
        }
    }
}
