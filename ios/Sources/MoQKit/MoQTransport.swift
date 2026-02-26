import Foundation

public final class MoQTransport: @unchecked Sendable {
    public let status: AsyncStream<Int32>
    private let sessionHandle: UInt32
    private let statusContinuation: AsyncStream<Int32>.Continuation

    private init(
        handle: UInt32,
        status: AsyncStream<Int32>,
        continuation: AsyncStream<Int32>.Continuation
    ) throws {
        // try moqLogLevel(level: "trace")
        self.sessionHandle = handle
        self.status = status
        self.statusContinuation = continuation
    }

    public static func connect(
        url: String,
        publishOrigin: UInt32 = 0,
        consumeOrigin: UInt32 = 0
    ) async throws -> MoQTransport {
        var cont: AsyncStream<Int32>.Continuation!
        let statusStream = AsyncStream<Int32> { cont = $0 }

        let cb = TransportCB(continuation: cont)
        let handle = try moqSessionConnect(
            url: url,
            originPublish: publishOrigin,
            originConsume: consumeOrigin,
            callback: cb
        )

        var iterator = statusStream.makeAsyncIterator()
        guard let firstStatus = await iterator.next() else {
            throw MoqError.Error(msg: "Connection failed: stream ended immediately")
        }
        if firstStatus < 0 {
            throw MoqError.Error(msg: "Connection failed with status \(firstStatus)")
        }

        return try MoQTransport(handle: handle, status: statusStream, continuation: cont)
    }

    public func close() async {
        try? moqSessionClose(session: sessionHandle)
        statusContinuation.finish()
    }
}

private final class TransportCB: SessionCallback {
    private let continuation: AsyncStream<Int32>.Continuation

    init(continuation: AsyncStream<Int32>.Continuation) {
        self.continuation = continuation
    }

    func onStatus(code: Int32) {
        continuation.yield(code)
        if code != 0 {
            continuation.finish()
        }
    }
}
