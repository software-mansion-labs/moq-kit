import Foundation

// MARK: - Media Track Base

public class MoQMediaTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    private let trackHandle: UInt32
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let rawContinuation: AsyncStream<UInt32>.Continuation
    private let closeFunc: (UInt32) throws -> Void

    fileprivate init(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64,
        subscribeFunc: (UInt32, UInt32, UInt64, any FrameCallback) throws -> UInt32,
        closeFunc: @escaping (UInt32) throws -> Void
    ) throws {
        var rawCont: AsyncStream<UInt32>.Continuation!
        let rawStream = AsyncStream<UInt32> { rawCont = $0 }

        var framesCont: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { framesCont = $0 }

        let cb = FrameCB(continuation: rawCont)
        let handle = try subscribeFunc(broadcastHandle, index, maxLatencyMs, cb)

        self.trackHandle = handle
        self.frames = frames
        self.framesContinuation = framesCont
        self.rawContinuation = rawCont
        self.closeFunc = closeFunc

        // Must be set after self is fully initialized
        framesCont.onTermination = { @Sendable [weak self] _ in
            Task { await self?.close() }
        }

        // Bridging Task: consumes raw IDs, calls moqConsumeFrame outside callback lock
        Task.detached {
            for await frameId in rawStream {
                defer { try? moqConsumeFrameClose(frame: frameId) }
                guard let frameData = try? moqConsumeFrame(frame: frameId) else {
                    continue
                }
                framesCont.yield(MoQFrame(
                    payload: frameData.payload,
                    timestampUs: frameData.timestampUs,
                    keyframe: frameData.keyframe
                ))
            }
            framesCont.finish()
        }
    }

    public func close() async {
        framesContinuation.finish()
        rawContinuation.finish()
        try? closeFunc(trackHandle)
    }

    deinit {
        framesContinuation.finish()
        rawContinuation.finish()
    }
}

// MARK: - Video Track

public final class MoQVideoTrack: MoQMediaTrack {
    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQVideoTrack {
        try MoQVideoTrack(
            broadcastHandle: broadcastHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: { try moqConsumeVideoOrdered(broadcast: $0, index: $1, maxLatencyMs: $2, callback: $3) },
            closeFunc: { try moqConsumeVideoClose(track: $0) }
        )
    }

    convenience init(from info: MoQVideoTrackInfo, broadcastHandle: UInt32, maxLatencyMs: UInt64) throws {
        try self.init(
            broadcastHandle: broadcastHandle,
            index: info.index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: { try moqConsumeVideoOrdered(broadcast: $0, index: $1, maxLatencyMs: $2, callback: $3) },
            closeFunc: { try moqConsumeVideoClose(track: $0) }
        )
    }
}

// MARK: - Audio Track

public final class MoQAudioTrack: MoQMediaTrack {
    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQAudioTrack {
        try MoQAudioTrack(
            broadcastHandle: broadcastHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: { try moqConsumeAudioOrdered(broadcast: $0, index: $1, maxLatencyMs: $2, callback: $3) },
            closeFunc: { try moqConsumeAudioClose(track: $0) }
        )
    }

    convenience init(from info: MoQAudioTrackInfo, broadcastHandle: UInt32, maxLatencyMs: UInt64) throws {
        try self.init(
            broadcastHandle: broadcastHandle,
            index: info.index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: { try moqConsumeAudioOrdered(broadcast: $0, index: $1, maxLatencyMs: $2, callback: $3) },
            closeFunc: { try moqConsumeAudioClose(track: $0) }
        )
    }
}

// MARK: - Frame Callback

private final class FrameCB: FrameCallback {
    private let continuation: AsyncStream<UInt32>.Continuation

    init(continuation: AsyncStream<UInt32>.Continuation) {
        self.continuation = continuation
    }

    func onFrame(frameId: UInt32) {
        continuation.yield(frameId)   // only safe: no Rust call inside callback
    }
}
