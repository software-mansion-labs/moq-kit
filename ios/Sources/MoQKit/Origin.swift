import Clibmoq

public struct AnnouncedBroadcast: Sendable {
    public let path: String
    public let active: Bool
}

public final class MoQOrigin: Sendable {
    public let handle: UInt32

    public init() throws {
        self.handle = try moq_origin_create().asHandle()
    }

    public func publish(_ broadcast: UInt32, path: String) throws {
        try path.withCStringLen { ptr, len in
            try moq_origin_publish(handle, ptr, len, broadcast).asSuccess()
        }
    }

    public func consume(path: String) throws -> UInt32 {
        try path.withCStringLen { ptr, len in
            try moq_origin_consume(handle, ptr, len).asHandle()
        }
    }

    public func announced() throws -> AsyncStream<AnnouncedBroadcast> {
        let (stream, callback, userData) = makeCallbackStream()

        let announcedHandle = try moq_origin_announced(handle, callback, userData).asHandle()

        return AsyncStream { continuation in
            let task = Task {
                for await rawId in stream {
                    if rawId < 0 {
                        continuation.finish()
                        break
                    }

                    var info = moq_announced()
                    let result = moq_origin_announced_info(UInt32(rawId), &info)
                    guard result >= 0 else {
                        continuation.finish()
                        break
                    }

                    let path: String
                    if let ptr = info.path, info.path_len > 0 {
                        path = String(
                            decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(info.path_len)),
                            as: UTF8.self
                        )
                    } else {
                        path = ""
                    }

                    continuation.yield(AnnouncedBroadcast(path: path, active: info.active))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                moq_origin_announced_close(announcedHandle)
            }
        }
    }

    public func close() throws {
        try moq_origin_close(handle).asSuccess()
    }

    deinit {
        moq_origin_close(handle)
    }
}
