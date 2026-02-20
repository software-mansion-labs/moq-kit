import Clibmoq
import Foundation

// MARK: - Video Track

public final class MoQVideoTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    private let resource: CallbackStreamHandle
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation

    private init(
        frames: AsyncStream<MoQFrame>,
        resource: CallbackStreamHandle,
        framesContinuation: AsyncStream<MoQFrame>.Continuation
    ) {
        self.frames = frames
        self.resource = resource
        self.framesContinuation = framesContinuation
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQVideoTrack {
        var continuation: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { continuation = $0 }

        let resource = try CallbackStreamHandle(
            label: "moq_consume_video_ordered",
            open: { cb, ud in
                try moq_consume_video_ordered(broadcastHandle, index, maxLatencyMs, cb, ud).asHandle()
            },
            close: { moq_consume_video_close($0) },
            onEvent: { handleId in 
                guard handleId >= 0 else { return }
                if let frame = readFrame(handle: UInt32(handleId)) {
                    continuation.yield(frame)
                }
            },
            onDone: { continuation.finish() }
        )


        let track = MoQVideoTrack(frames: frames, resource: resource, framesContinuation: continuation)

        continuation.onTermination = { @Sendable [weak track] _ in
            Task { await track?.close() }
        }

        return track
    }

    public func close() async {
        framesContinuation.finish()
        await resource.close()
    }

    deinit {
        framesContinuation.finish()
    }
}

// MARK: - Audio Track

public final class MoQAudioTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    private let resource: CallbackStreamHandle
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation

    private init(
        frames: AsyncStream<MoQFrame>,
        resource: CallbackStreamHandle,
        framesContinuation: AsyncStream<MoQFrame>.Continuation
    ) {
        self.frames = frames
        self.resource = resource
        self.framesContinuation = framesContinuation
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQAudioTrack {
        var continuation: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { continuation = $0 }

        let resource = try CallbackStreamHandle(
            label: "moq_consume_audio_ordered",
            open: { cb, ud in
                try moq_consume_audio_ordered(broadcastHandle, index, maxLatencyMs, cb, ud).asHandle()
            },
            close: { moq_consume_audio_close($0) },
            onEvent: { handleId in
                guard handleId >= 0 else { return }

                if let frame = readFrame(handle: UInt32(handleId)) {
                    continuation.yield(frame)
                }
            },
            onDone: { continuation.finish() }
        )


        let track = MoQAudioTrack(frames: frames, resource: resource,
                                  framesContinuation: continuation)


        continuation.onTermination = { @Sendable [weak track] _ in
            Task { await track?.close() }
        }

        return track
    }

    public func close() async {
        framesContinuation.finish()
        await resource.close()
    }

    deinit {
        framesContinuation.finish()
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
