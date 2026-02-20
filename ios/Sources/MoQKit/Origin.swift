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

    /// Waits until the server announces the given path, then consumes it.
    /// Returns the broadcast handle, or throws if the announcement stream ends without finding the path.
    public func consume(waitingForPath path: String) async throws -> UInt32 {
        for await announced in try announced() {
            if announced.path == path {
                return try consume(path: path)
            }
        }
        throw MoQError(code: -1) // stream ended without seeing the path
    }

    public func announced() throws -> AsyncStream<AnnouncedBroadcast> {
        let lease = makeCallbackStream(label: "moq_origin_announced")

        let announcedHandle = try moq_origin_announced(handle, lease.callback, lease.userData).asHandle()

        return AsyncStream { continuation in
            let task = Task {
                for await rawId in lease.stream {
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
                moq_origin_announced_close(announcedHandle)
                lease.release()
                task.cancel()
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
