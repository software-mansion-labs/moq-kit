import Foundation

// MARK: - Video Track

public final class MoQVideoTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    private let trackHandle: UInt32
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let rawContinuation: AsyncStream<UInt32>.Continuation

    private init(
        handle: UInt32,
        frames: AsyncStream<MoQFrame>,
        framesContinuation: AsyncStream<MoQFrame>.Continuation,
        rawContinuation: AsyncStream<UInt32>.Continuation
    ) {
        self.trackHandle = handle
        self.frames = frames
        self.framesContinuation = framesContinuation
        self.rawContinuation = rawContinuation
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQVideoTrack {
        // Inner stream: raw IDs only, fed by callback (no Rust calls inside callback)
        var rawCont: AsyncStream<UInt32>.Continuation!
        let rawStream = AsyncStream<UInt32> { rawCont = $0 }

        var framesCont: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { framesCont = $0 }

        let cb = FrameCB(continuation: rawCont)
        let handle = try moqConsumeVideoOrdered(
            broadcast: broadcastHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            callback: cb
        )

        let track = MoQVideoTrack(
            handle: handle,
            frames: frames,
            framesContinuation: framesCont,
            rawContinuation: rawCont
        )

        framesCont.onTermination = { @Sendable [weak track] _ in
            Task { await track?.close() }
        }

        // Bridging Task: consumes raw IDs, calls moqConsumeFrame outside callback lock
        Task.detached {
            for await frameId in rawStream {
                defer { try? moqConsumeFrameClose(frame: frameId) }
                guard let frameData = try? moqConsumeFrame(frame: frameId) else { continue }
                framesCont.yield(MoQFrame(
                    payload: frameData.payload,
                    timestampUs: frameData.timestampUs,
                    keyframe: frameData.keyframe
                ))
            }
            framesCont.finish()
        }

        return track
    }

    public func close() async {
        framesContinuation.finish()
        rawContinuation.finish()          // stops bridging Task
        try? moqConsumeVideoClose(track: trackHandle)
    }

    deinit {
        framesContinuation.finish()
        rawContinuation.finish()
    }
}

// MARK: - Audio Track

public final class MoQAudioTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    private let trackHandle: UInt32
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let rawContinuation: AsyncStream<UInt32>.Continuation

    private init(
        handle: UInt32,
        frames: AsyncStream<MoQFrame>,
        framesContinuation: AsyncStream<MoQFrame>.Continuation,
        rawContinuation: AsyncStream<UInt32>.Continuation
    ) {
        self.trackHandle = handle
        self.frames = frames
        self.framesContinuation = framesContinuation
        self.rawContinuation = rawContinuation
    }

    public static func subscribe(
        broadcastHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQAudioTrack {
        // Inner stream: raw IDs only, fed by callback (no Rust calls inside callback)
        var rawCont: AsyncStream<UInt32>.Continuation!
        let rawStream = AsyncStream<UInt32> { rawCont = $0 }

        var framesCont: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { framesCont = $0 }

        let cb = FrameCB(continuation: rawCont)
        let handle = try moqConsumeAudioOrdered(
            broadcast: broadcastHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            callback: cb
        )

        let track = MoQAudioTrack(
            handle: handle,
            frames: frames,
            framesContinuation: framesCont,
            rawContinuation: rawCont
        )

        framesCont.onTermination = { @Sendable [weak track] _ in
            Task { await track?.close() }
        }

        // Bridging Task: consumes raw IDs, calls moqConsumeFrame outside callback lock
        Task.detached {
            for await frameId in rawStream {
                defer { try? moqConsumeFrameClose(frame: frameId) }
                guard let frameData = try? moqConsumeFrame(frame: frameId) else { continue }
                framesCont.yield(MoQFrame(
                    payload: frameData.payload,
                    timestampUs: frameData.timestampUs,
                    keyframe: frameData.keyframe
                ))
            }
            framesCont.finish()
        }

        return track
    }

    public func close() async {
        framesContinuation.finish()
        rawContinuation.finish()          // stops bridging Task
        try? moqConsumeAudioClose(track: trackHandle)
    }

    deinit {
        framesContinuation.finish()
        rawContinuation.finish()
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
