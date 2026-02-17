import Foundation

final class CallbackContext: Sendable {
    let continuation: AsyncStream<Int32>.Continuation

    init(_ continuation: AsyncStream<Int32>.Continuation) {
        self.continuation = continuation
    }
}

func makeCallbackStream() -> (
    stream: AsyncStream<Int32>,
    callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void,
    userData: UnsafeMutableRawPointer
) {
    var continuation: AsyncStream<Int32>.Continuation!
    let stream = AsyncStream<Int32> { continuation = $0 }

    let context = CallbackContext(continuation)
    let userData = Unmanaged.passRetained(context).toOpaque()

    let rawAddr = Int(bitPattern: userData)
    continuation.onTermination = { @Sendable _ in
        let ptr = UnsafeMutableRawPointer(bitPattern: rawAddr)!
        Unmanaged<CallbackContext>.fromOpaque(ptr).release()
    }

    let callback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ptr, value in
        guard let ptr else { return }
        let ctx = Unmanaged<CallbackContext>.fromOpaque(ptr).takeUnretainedValue()
        ctx.continuation.yield(value)
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
