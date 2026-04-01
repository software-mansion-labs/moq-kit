import Foundation
import MoQKitFFI

// MARK: - MoQFrame

/// A single compressed media frame received from the relay.
///
/// Frames are delivered in presentation order on ``MoQMediaTrack/frames``.
/// Most consumers should use ``MoQPlayer`` rather than working with frames directly.
public struct MoQFrame: Sendable {
    /// The raw compressed payload bytes (e.g. an H.264 NAL unit, an AAC packet).
    public let payload: Data
    /// Presentation timestamp in microseconds, relative to the stream origin.
    public let timestampUs: UInt64
    /// Whether this frame is a keyframe (sync point). Keyframes can be decoded independently
    /// without prior frames.
    public let keyframe: Bool

    init(_ raw: MoqFrame) {
        self.payload = raw.payload
        self.timestampUs = raw.timestampUs
        self.keyframe = raw.keyframe
    }
}

// MARK: - Track State

/// The lifecycle state of a ``MoQMediaTrack``.
public enum MoQTrackState: Sendable, Equatable {
    /// Subscribed to the track but no frames have arrived yet.
    case idle
    /// Frames are arriving and being emitted on ``MoQMediaTrack/frames``.
    case active
    /// The track ended normally (the remote sender closed it).
    case closed
    /// The track ended with an error. The associated string contains a human-readable description.
    case error(String)
}

// MARK: - Media Track

/// A low-level subscription to a single MoQ media track.
///
/// `MoQMediaTrack` surfaces raw ``MoQFrame`` values from the relay. In most cases you should
/// use ``MoQPlayer`` instead, which manages subscriptions and rendering internally.
///
/// Both ``frames`` and ``state`` are `AsyncStream`s that complete when the track ends or when
/// ``close()`` is called.
public final class MoQMediaTrack: @unchecked Sendable {
    /// A stream of raw media frames as they arrive from the relay.
    public let frames: AsyncStream<MoQFrame>
    /// A stream of ``MoQTrackState`` transitions. Always yields `.idle` as its first element.
    public let state: AsyncStream<MoQTrackState>

    private let track: MoqMediaConsumer
    private let framesContinuation: AsyncStream<MoQFrame>.Continuation
    private let stateContinuation: AsyncStream<MoQTrackState>.Continuation
    private var readTask: Task<Void, Never>?

    init(
        broadcast: MoqBroadcastConsumer, name: String, container: Container,
        maxLatencyMs: UInt64
    ) throws {
        let track = try broadcast.subscribeMedia(name: name, container: container, maxLatencyMs: maxLatencyMs)

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
                    guard let frame = try await track.next() else {
                        stateCont.yield(.closed)
                        return
                    }
                    if isFirstFrame {
                        stateCont.yield(.active)
                        isFirstFrame = false
                    }
                    framesCont.yield(MoQFrame(frame))
                } catch {
                    stateCont.yield(.error(error.localizedDescription))
                    return
                }
            }
        }
    }

    /// Cancels the track subscription and completes both ``frames`` and ``state`` streams.
    ///
    /// Safe to call multiple times.
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
