import Clibmoq

public final class MoQSession: Sendable {
    public let handle: UInt32
    public let status: AsyncStream<Int32>

    private init(handle: UInt32, status: AsyncStream<Int32>) {
        self.handle = handle
        self.status = status
    }

    public static func connect(
        url: String,
        publishOrigin: UInt32 = 0,
        consumeOrigin: UInt32 = 0
    ) async throws -> MoQSession {
        let (stream, callback, userData) = makeCallbackStream()

        let handle = try url.withCStringLen { ptr, len in
            try moq_session_connect(ptr, len, publishOrigin, consumeOrigin, callback, userData).asHandle()
        }

        var iterator = stream.makeAsyncIterator()

        guard let firstStatus = await iterator.next() else {
            throw MoQError(code: -1)
        }

        if firstStatus < 0 {
            throw MoQError(code: firstStatus)
        }

        // Wrap remaining status updates into a new stream
        let remaining = AsyncStream<Int32> { continuation in
            let task = Task {
                while let value = await iterator.next() {
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return MoQSession(handle: handle, status: remaining)
    }

    public func close() throws {
        try moq_session_close(handle).asSuccess()
    }

    deinit {
        moq_session_close(handle)
    }
}
