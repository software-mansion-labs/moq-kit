import Clibmoq
import Foundation

// MARK: - Config Types

public struct VideoConfig: Sendable {
    public let name: String
    public let codec: String
    public let codecDescription: Data?
    public let codedWidth: UInt32?
    public let codedHeight: UInt32?
}

public struct AudioConfig: Sendable {
    public let name: String
    public let codec: String
    public let codecDescription: Data?
    public let sampleRate: UInt32
    public let channelCount: UInt32
}

// MARK: - Frame

public struct MoQFrame: Sendable {
    public let payload: Data
    public let timestampUs: UInt64
    public let keyframe: Bool
}

// MARK: - Internal Helpers

private func makeString(ptr: UnsafePointer<CChar>?, len: UInt) -> String {
    guard let ptr, len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(len)), as: UTF8.self)
}

private func makeData(ptr: UnsafePointer<UInt8>?, len: UInt) -> Data? {
    guard let ptr, len > 0 else { return nil }
    return Data(bytes: ptr, count: Int(len))
}

// MARK: - Catalog Subscription

/// Delivers catalog updates for a broadcast. The callback lease is kept alive for the
/// lifetime of this object; dropping it stops delivery on the Swift side but does not
/// issue any C close call (there is no C API to cancel catalog updates explicitly).
public final class MoQCatalogSubscription: Sendable {
    public let catalogs: AsyncStream<MoQCatalog>
    // Holds the C callback context alive until this subscription is released.
    private let resource: CallbackStreamHandle

    init(broadcastHandle: UInt32) throws {
        var continuation: AsyncStream<MoQCatalog>.Continuation!
        let catalogs = AsyncStream<MoQCatalog> { continuation = $0 }

        self.resource = try CallbackStreamHandle(
            label: "moq_consume_catalog",
            open: { cb, ud in try moq_consume_catalog(broadcastHandle, cb, ud).asHandle() },
            close: { moq_consume_close($0) },
            onEvent: { handleId in 
                if handleId >= 0 {
                    continuation.yield(MoQCatalog(handle: UInt32(handleId)))
                }
            },
            onDone: { continuation.finish() }
        )

        self.catalogs = catalogs
    }
}

// MARK: - Catalog

public final class MoQCatalog: Sendable {
    public let handle: UInt32

    fileprivate init(handle: UInt32) {
        self.handle = handle
    }

    /// Subscribes to catalog updates and returns the first catalog that arrives.
    /// For ongoing updates use `subscribeUpdates(broadcastHandle:)`.
    public static func subscribe(broadcastHandle: UInt32) async throws -> MoQCatalog {
        let subscription = try MoQCatalogSubscription(broadcastHandle: broadcastHandle)
        var iterator = subscription.catalogs.makeAsyncIterator()
        guard let first = await iterator.next() else {
            throw MoQError(code: -1)
        }
        return first
    }

    /// Returns a subscription that emits a `MoQCatalog` each time the broadcast
    /// publishes a new catalog. Keep the subscription alive for as long as updates
    /// are needed; the callback context is released when it is dropped.
    public static func subscribeUpdates(broadcastHandle: UInt32) throws -> MoQCatalogSubscription {
        return try MoQCatalogSubscription(broadcastHandle: broadcastHandle)
    }

    public func videoConfig(at index: UInt32) throws -> VideoConfig {
        var cfg = moq_video_config()
        try moq_consume_video_config(handle, index, &cfg).asSuccess()

        return VideoConfig(
            name: makeString(ptr: cfg.name, len: cfg.name_len),
            codec: makeString(ptr: cfg.codec, len: cfg.codec_len),
            codecDescription: makeData(ptr: cfg.description, len: cfg.description_len),
            codedWidth: cfg.coded_width != nil ? cfg.coded_width.pointee : nil,
            codedHeight: cfg.coded_height != nil ? cfg.coded_height.pointee : nil
        )
    }

    public func audioConfig(at index: UInt32) throws -> AudioConfig {
        var cfg = moq_audio_config()
        try moq_consume_audio_config(handle, index, &cfg).asSuccess()

        return AudioConfig(
            name: makeString(ptr: cfg.name, len: cfg.name_len),
            codec: makeString(ptr: cfg.codec, len: cfg.codec_len),
            codecDescription: makeData(ptr: cfg.description, len: cfg.description_len),
            sampleRate: cfg.sample_rate,
            channelCount: cfg.channel_count
        )
    }

    public func close() {
        moq_consume_catalog_close(handle)
    }

    deinit {
        moq_consume_catalog_close(handle)
    }
}

