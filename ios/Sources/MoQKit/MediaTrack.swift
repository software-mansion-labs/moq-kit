import Foundation

// MARK: - Track State

public enum MoQTrackState: Sendable, Equatable {
    case idle  // subscribed, awaiting first frame
    case active  // receiving frames
    case closed
    case error(String)
}

// MARK: - Media Track

public final class MoQMediaTrack: @unchecked Sendable {
    public let frames: AsyncStream<MoQFrame>
    public let state: AsyncStream<MoQTrackState>

    private let track: MoqTrack
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let stateContinuation: AsyncStream<MoQTrackState>.Continuation
    private var readTask: Task<Void, Never>?

    init(broadcast: MoqBroadcast, name: String, maxLatencyMs: UInt64) async throws {
        let track = try await broadcast.subscribeTrack(name: name, maxLatencyMs: maxLatencyMs)
        self.track = track

        var framesCont: AsyncStream<MoQFrame>.Continuation!
        let framesStream = AsyncStream<MoQFrame> { framesCont = $0 }

        var stateCont: AsyncStream<MoQTrackState>.Continuation!
        let stateStream = AsyncStream<MoQTrackState> { stateCont = $0 }

        self.frames = framesStream
        self.state = stateStream
        self.framesContinuation = framesCont
        self.stateContinuation = stateCont

        stateCont.yield(.idle)

        readTask = Task.detached {
            var isFirstFrame = true
            defer {
                framesCont.finish()
                stateCont.finish()
            }

            while !Task.isCancelled {
                do {
                    guard let frameData = try await track.next() else {
                        stateCont.yield(.closed)
                        return
                    }
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

    public func close() {
        track.close()
        readTask?.cancel()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
        framesContinuation.finish()
    }

    deinit {
        track.close()
        readTask?.cancel()
        stateContinuation.finish()
        framesContinuation.finish()
    }
}
