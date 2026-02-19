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

func makeCallbackStream(label: String) -> (
    stream: AsyncStream<Int32>,
    callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void,
    userData: UnsafeMutableRawPointer
) {
    var continuation: AsyncStream<Int32>.Continuation!
    let stream = AsyncStream<Int32> { continuation = $0 }

    let context = CallbackContext(continuation, label: label)
    let userData = Unmanaged.passRetained(context).toOpaque()

    // DEBUG: stash label by address so the callback can always read it even after context is freed
    _debugLabels[Int(bitPattern: userData)] = label

    let rawAddr = Int(bitPattern: userData)
    continuation.onTermination = { @Sendable _ in
        print("terminating \(label)")
        let ptr = UnsafeMutableRawPointer(bitPattern: rawAddr)!
        Unmanaged<CallbackContext>.fromOpaque(ptr).release()
    }

    let callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ptr, value in
        let label = _debugLabels[Int(bitPattern: ptr)] ?? "<unknown:\(String(describing: ptr))>"
        print("[CallbackBridge] \(label) called with value: \(value)")
        guard let ptr else { return }
        let ctx = Unmanaged<CallbackContext>.fromOpaque(ptr).takeUnretainedValue()
        ctx.continuation.yield(value)
        print("[CallbackBridge] \(label) after yield")
    }

    return (stream, callback, userData)
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
