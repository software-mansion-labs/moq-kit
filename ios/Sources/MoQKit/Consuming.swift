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

// MARK: - Catalog

public final class MoQCatalog: Sendable {
    public let handle: UInt32

    private init(handle: UInt32) {
        self.handle = handle
    }

    public static func subscribe(broadcastHandle: UInt32) async throws -> MoQCatalog {
        let (stream, callback, userData) = makeCallbackStream(label: "moq_consume_catalog")

        _ = try moq_consume_catalog(broadcastHandle, callback, userData).asHandle()

        var iterator = stream.makeAsyncIterator()

        guard let firstCatalog = await iterator.next() else {
            throw MoQError(code: -1)
        }

        let catalogHandle = try firstCatalog.asHandle()
        return MoQCatalog(handle: catalogHandle)
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

// MARK: - Video Track

public final class MoQVideoTrack: Sendable {
    public let handle: UInt32
    public let frames: AsyncStream<MoQFrame>

    private init(handle: UInt32, frames: AsyncStream<MoQFrame>) {
        self.handle = handle
        self.frames = frames
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQVideoTrack {
        let (stream, callback, userData) = makeCallbackStream(label: "moq_consume_video_ordered")

        let trackHandle = try moq_consume_video_ordered(
            broadcastHandle, index, maxLatencyMs, callback, userData
        ).asHandle()

        let frames = AsyncStream<MoQFrame> { continuation in
            let task = Task {
                for await rawFrameId in stream {
                    if rawFrameId < 0 {
                        continuation.finish()
                        break
                    }

                    let frameHandle = UInt32(rawFrameId)
                    if let frame = readFrame(handle: frameHandle) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel() } }

        return MoQVideoTrack(handle: trackHandle, frames: frames)
    }

    public func close() {
        moq_consume_video_close(handle)
    }

    deinit {
        moq_consume_video_close(handle)
    }
}

// MARK: - Audio Track

public final class MoQAudioTrack: Sendable {
    public let handle: UInt32
    public let frames: AsyncStream<MoQFrame>

    private init(handle: UInt32, frames: AsyncStream<MoQFrame>) {
        self.handle = handle
        self.frames = frames
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQAudioTrack {
        let (stream, callback, userData) = makeCallbackStream(label: "moq_consume_audio_ordered")

        let trackHandle = try moq_consume_audio_ordered(
            broadcastHandle, index, maxLatencyMs, callback, userData
        ).asHandle()

        let frames = AsyncStream<MoQFrame> { continuation in
            let task = Task {
                for await rawFrameId in stream {
                    if rawFrameId < 0 {
                        continuation.finish()
                        break
                    }

                    let frameHandle = UInt32(rawFrameId)
                    if let frame = readFrame(handle: frameHandle) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return MoQAudioTrack(handle: trackHandle, frames: frames)
    }

    public func close() {
        moq_consume_audio_close(handle)
    }

    deinit {
        moq_consume_audio_close(handle)
    }
}

// MARK: - Frame Chunk Assembly

private func readFrame(handle: UInt32) -> MoQFrame? {
    var payload = Data()
    var timestampUs: UInt64 = 0
    var keyframe = false
    var index: UInt32 = 0

    while true {
        var chunk = moq_frame()
        let result = moq_consume_frame_chunk(handle, index, &chunk)

        if result < 0 {
            break
        }

        if chunk.payload == nil || chunk.payload_size == 0 {
            moq_consume_frame_close(handle)
            return nil
        }

        payload.append(chunk.payload, count: Int(chunk.payload_size))

        if index == 0 {
            timestampUs = chunk.timestamp_us
            keyframe = chunk.keyframe
        }

        index += 1
    }

    moq_consume_frame_close(handle)

    guard !payload.isEmpty else { return nil }

    return MoQFrame(payload: payload, timestampUs: timestampUs, keyframe: keyframe)
}

// MARK: - Broadcast Consumer

public func closeBroadcastConsumer(_ handle: UInt32) throws {
    try moq_consume_close(handle).asSuccess()
}
