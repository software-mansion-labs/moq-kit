import Clibmoq
import Foundation

public final class MoQTransport: @unchecked Sendable {
    public let status: AsyncStream<Int32>
    private let resource: CallbackStreamHandle

    private init(
        status: AsyncStream<Int32>,
        resource: CallbackStreamHandle
    ) throws {
        try MoQ.setupLogger(logLevel: MoQ.LogLevel.trace)

        self.status = status
        self.resource = resource
    }

    public static func connect(
        url: String,
        publishOrigin: UInt32 = 0,
        consumeOrigin: UInt32 = 0
    ) async throws -> MoQTransport {
        var statusContinuation: AsyncStream<Int32>.Continuation!
        let status = AsyncStream<Int32> { statusContinuation = $0 }

        let resource = try CallbackStreamHandle(
            label: "moq_session_connect",
            open: { cb, ud in
                try url.withCStringLen { ptr, len in
                    try moq_session_connect(ptr, len, publishOrigin, consumeOrigin, cb, ud).asHandle()
                }
            },
            close: { _ = moq_session_close($0) },
            onEvent: { statusContinuation.yield($0) },
            onDone: { statusContinuation.finish() }
        )

        var iterator = status.makeAsyncIterator()

        guard let firstStatus = await iterator.next()else {
            throw MoQError(code: -1)
        }

        if firstStatus < 0 {
            throw MoQError(code: firstStatus)
        }

        return try MoQTransport(status: status, resource: resource)
    }

    /// Closes the session. Idempotent.
    public func close() async throws {
        await resource.close()
    }
}
