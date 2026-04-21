import Foundation
import MoQKitFFI

// MARK: - MediaFrame

/// A single compressed media frame received from the relay.
///
/// Frames are delivered in presentation order on ``MediaTrack/frames``.
/// Most consumers should use ``Player`` rather than working with frames directly.
public struct MediaFrame: Sendable {
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

/// The lifecycle state of a ``MediaTrack``.
public enum MediaTrackState: Sendable, Equatable {
    /// Subscribed to the track but no frames have arrived yet.
    case idle
    /// Frames are arriving and being emitted on ``MediaTrack/frames``.
    case active
    /// The track ended normally (the remote sender closed it).
    case closed
    /// The track ended with an error. The associated string contains a human-readable description.
    case error(String)
}

// MARK: - Media Track

/// A low-level subscription to a single MoQ media track.
///
/// `MediaTrack` surfaces raw ``MediaFrame`` values from the relay. In most cases you should
/// use ``Player`` instead, which manages subscriptions and rendering internally.
///
/// Both ``frames`` and ``state`` are `AsyncStream`s that complete when the track ends or when
/// ``close()`` is called.
public final class MediaTrack: @unchecked Sendable {
    /// A stream of raw media frames as they arrive from the relay.
    public let frames: AsyncStream<MediaFrame>
    /// A stream of ``MediaTrackState`` transitions. Always yields `.idle` as its first element.
    public let state: AsyncStream<MediaTrackState>

    private let track: MoqMediaConsumer
    private let framesContinuation: AsyncStream<MediaFrame>.Continuation
    private let stateContinuation: AsyncStream<MediaTrackState>.Continuation
    private var readTask: Task<Void, Never>?

    init(
        broadcast: MoqBroadcastConsumer, name: String, container: Container,
        maxLatencyMs: UInt64
    ) throws {
        let track = try broadcast.subscribeMedia(name: name, container: container, maxLatencyMs: maxLatencyMs)

        self.track = track

        var framesCont: AsyncStream<MediaFrame>.Continuation!
        let framesStream = AsyncStream<MediaFrame> { framesCont = $0 }

        var stateCont: AsyncStream<MediaTrackState>.Continuation!
        let stateStream = AsyncStream<MediaTrackState> { stateCont = $0 }

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
                    framesCont.yield(MediaFrame(frame))
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
        readTask = nil
        // Do not yield .closed here — the read task's defer handles that on a normal
        // end, and double-yielding would emit two .closed events to state consumers.
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
