import Foundation

// MARK: - Track State

public enum MoQTrackState: Sendable, Equatable {
    case idle  // subscribed, awaiting first frame
    case active  // receiving frames
    case closed
    case error(String)
}

// MARK: - Media Track Base

public class MoQMediaTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    public let state: AsyncStream<MoQTrackState>

    private let trackHandle: UInt32
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let stateContinuation: AsyncStream<MoQTrackState>.Continuation
    private let rawFrameContinuation: AsyncStream<Int32>.Continuation
    private let closeFunc: (UInt32) throws -> Void
    private var bridgingTask: Task<Void, Never>?

    fileprivate init(
        catalogHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64,
        subscribeFunc: (UInt32, UInt32, UInt64, any FrameCallback) throws -> UInt32,
        closeFunc: @escaping (UInt32) throws -> Void
    ) throws {
        var rawCont: AsyncStream<Int32>.Continuation!
        let rawStream = AsyncStream<Int32> { rawCont = $0 }

        var framesCont: AsyncStream<MoQFrame>.Continuation!
        let frames = AsyncStream<MoQFrame> { framesCont = $0 }

        var stateCont: AsyncStream<MoQTrackState>.Continuation!
        let state = AsyncStream<MoQTrackState> { stateCont = $0 }

        let cb = FrameCB(continuation: rawCont)
        let handle = try subscribeFunc(catalogHandle, index, maxLatencyMs, cb)

        self.trackHandle = handle
        self.frames = frames
        self.state = state
        self.framesContinuation = framesCont
        self.stateContinuation = stateCont
        self.rawFrameContinuation = rawCont
        self.closeFunc = closeFunc

        stateCont.yield(.idle)

        // Must be set after self is fully initialized
        framesCont.onTermination = { _ in
            try? closeFunc(handle)
        }

        // Bridging Task: consumes raw IDs, calls moqConsumeFrame outside callback lock
        bridgingTask = Task.detached {
            var isFirstFrame = true
            defer { framesCont.finish() }

            for await rawId in rawStream {
                if Task.isCancelled { break }

                if rawId <= 0 {
                    if rawId == 0 {
                        stateCont.yield(.closed)
                    } else {
                        stateCont.yield(.error("Invalid frame ID: \(rawId)"))
                    }
                    return
                }

                let frameId = UInt32(bitPattern: rawId)

                defer { try? moqConsumeFrameClose(frame: frameId) }

                do {
                    let frameData = try moqConsumeFrame(frame: frameId)
                    if isFirstFrame {
                        stateCont.yield(.active)
                        isFirstFrame = false
                    }
                    framesCont.yield(
                        MoQFrame(
                            payload: frameData.payload,
                            timestampUs: frameData.timestampUs,
                            keyframe: frameData.keyframe
                        ))
                } catch {
                    stateCont.yield(.error(error.localizedDescription))
                    return
                }
            }
        }
    }

    public func close() async {
        bridgingTask?.cancel()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
        framesContinuation.finish()
        rawFrameContinuation.finish()
        try? closeFunc(trackHandle)
    }

    deinit {
        bridgingTask?.cancel()
        stateContinuation.finish()
        framesContinuation.finish()
        rawFrameContinuation.finish()
    }
}

// MARK: - Video Track

public final class MoQVideoTrack: MoQMediaTrack, @unchecked Sendable {
    public static func subscribe(
        catalogHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQVideoTrack {
        try MoQVideoTrack(
            catalogHandle: catalogHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: {
                try moqConsumeVideoOrdered(catalog: $0, index: $1, maxLatencyMs: $2, callback: $3)
            },
            closeFunc: { try moqConsumeVideoClose(track: $0) }
        )
    }

    convenience init(from info: MoQVideoTrackInfo, maxLatencyMs: UInt64) throws {
        try self.init(
            catalogHandle: info.catalog.handle,
            index: info.index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: {
                try moqConsumeVideoOrdered(catalog: $0, index: $1, maxLatencyMs: $2, callback: $3)
            },
            closeFunc: { try moqConsumeVideoClose(track: $0) }
        )
    }
}

// MARK: - Audio Track

public final class MoQAudioTrack: MoQMediaTrack, @unchecked Sendable {
    public static func subscribe(
        catalogHandle: UInt32,
        index: UInt32,
        maxLatencyMs: UInt64
    ) throws -> MoQAudioTrack {
        try MoQAudioTrack(
            catalogHandle: catalogHandle,
            index: index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: {
                try moqConsumeAudioOrdered(catalog: $0, index: $1, maxLatencyMs: $2, callback: $3)
            },
            closeFunc: { try moqConsumeAudioClose(track: $0) }
        )
    }

    convenience init(from info: MoQAudioTrackInfo, maxLatencyMs: UInt64) throws {
        try self.init(
            catalogHandle: info.catalog.handle,
            index: info.index,
            maxLatencyMs: maxLatencyMs,
            subscribeFunc: {
                try moqConsumeAudioOrdered(catalog: $0, index: $1, maxLatencyMs: $2, callback: $3)
            },
            closeFunc: { try moqConsumeAudioClose(track: $0) }
        )
    }
}

// MARK: - Frame Callback

private final class FrameCB: FrameCallback {
    private let continuation: AsyncStream<Int32>.Continuation

    init(continuation: AsyncStream<Int32>.Continuation) {
        self.continuation = continuation
    }

    func onFrame(frameId: Int32) {
        continuation.yield(frameId)
    }
}
