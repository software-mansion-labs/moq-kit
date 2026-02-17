import Clibmoq
import Foundation

public final class MoQBroadcast: Sendable {
    public let handle: UInt32

    public init() throws {
        self.handle = try moq_publish_create().asHandle()
    }

    public func addMediaTrack(format: String, initData: Data) throws -> MoQMediaTrack {
        let trackHandle = try format.withCStringLen { fmtPtr, fmtLen in
            try initData.withUnsafeBytesLen { initPtr, initLen in
                try moq_publish_media_ordered(handle, fmtPtr, fmtLen, initPtr, initLen).asHandle()
            }
        }
        return MoQMediaTrack(handle: trackHandle)
    }

    public func close() throws {
        try moq_publish_close(handle).asSuccess()
    }

    deinit {
        moq_publish_close(handle)
    }
}

public final class MoQMediaTrack: Sendable {
    public let handle: UInt32

    init(handle: UInt32) {
        self.handle = handle
    }

    public func writeFrame(payload: Data, timestampUs: UInt64) throws {
        try payload.withUnsafeBytesLen { ptr, len in
            try moq_publish_media_frame(handle, ptr, len, timestampUs).asSuccess()
        }
    }

    public func close() throws {
        try moq_publish_media_close(handle).asSuccess()
    }

    deinit {
        moq_publish_media_close(handle)
    }
}
