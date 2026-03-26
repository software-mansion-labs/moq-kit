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
    public let frames: AsyncStream<MoqFrame>
    public let state: AsyncStream<MoQTrackState>

    private let track: MoqMediaConsumer
    private let framesContinuation: AsyncStream<MoqFrame>.Continuation
    private let stateContinuation: AsyncStream<MoQTrackState>.Continuation
    private var readTask: Task<Void, Never>?

    init(
        broadcast: MoqBroadcastConsumer, name: String, container: Container,
        maxLatencyMs: UInt64
    ) throws {
        let track = try broadcast.subscribeMedia(name: name, container: container, maxLatencyMs: maxLatencyMs)

        self.track = track

        var framesCont: AsyncStream<MoqFrame>.Continuation!
        let framesStream = AsyncStream<MoqFrame> { framesCont = $0 }

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
                    guard let frame = try await track.next() else {
                        stateCont.yield(.closed)
                        return
                    }
                    if isFirstFrame {
                        stateCont.yield(.active)
                        isFirstFrame = false
                    }
                    framesCont.yield(frame)
                } catch {
                    stateCont.yield(.error(error.localizedDescription))
                    return
                }
            }
        }
    }

    public func close() {
        track.cancel()
        readTask?.cancel()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
        framesContinuation.finish()
    }

    deinit {
        track.cancel()
        readTask?.cancel()
        stateContinuation.finish()
        framesContinuation.finish()
    }
}
