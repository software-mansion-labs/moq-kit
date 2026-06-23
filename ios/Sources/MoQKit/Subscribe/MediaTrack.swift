import Foundation
import MoqFFI

// MARK: - Media Container

/// Container format used by a MoQ media track.
///
/// Catalog-advertised tracks provide this automatically via ``AudioTrackInfo`` and
/// ``VideoTrackInfo``. Advanced callers can provide it directly when subscribing to a known
/// media track that is not advertised in the catalog.
public enum MediaContainer: Sendable, Equatable, Hashable {
    /// Legacy MoQ media container.
    case legacy
    /// CMAF/fMP4 media container with the initialization segment bytes.
    case cmaf(initializationData: Data)
    /// LOC media container.
    case loc

    init(_ raw: Container) {
        switch raw {
        case .legacy:
            self = .legacy
        case .cmaf(let initializationData):
            self = .cmaf(initializationData: initializationData)
        case .loc:
            self = .loc
        }
    }

    var rawContainer: Container {
        switch self {
        case .legacy:
            return .legacy
        case .cmaf(let initializationData):
            return .cmaf(init: initializationData)
        case .loc:
            return .loc
        }
    }
}

// MARK: - Media Track Request

/// Parameters needed to subscribe to a MoQ media track.
///
/// Use this when subscribing to media by name from a ``Broadcast`` without relying on catalog
/// metadata. When multiple consumers subscribe to the same track, the first subscriber creates
/// the shared upstream subscription and chooses its ``targetBuffering``.
public struct MediaTrackRequest: Sendable, Equatable {
    /// Track name on the broadcast.
    public let name: String
    /// Track container format.
    public let container: MediaContainer
    /// Target live buffering depth for the upstream media subscription.
    public let targetBuffering: Duration

    public init(
        name: String,
        container: MediaContainer,
        targetBuffering: Duration = .milliseconds(100)
    ) {
        self.name = name
        self.container = container
        self.targetBuffering = targetBuffering
    }

    init(track: AudioTrackInfo, targetBuffering: Duration) {
        self.init(
            name: track.name,
            container: MediaContainer(track.rawConfig.container),
            targetBuffering: targetBuffering
        )
    }

    init(track: VideoTrackInfo, targetBuffering: Duration) {
        self.init(
            name: track.name,
            container: MediaContainer(track.rawConfig.container),
            targetBuffering: targetBuffering
        )
    }
}

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

    init(payload: Data, timestampUs: UInt64, keyframe: Bool) {
        self.payload = payload
        self.timestampUs = timestampUs
        self.keyframe = keyframe
    }
}

// MARK: - Media Track Options

/// Buffering behavior for frames emitted by a ``MediaTrack``.
public enum MediaTrackBufferingPolicy: Sendable, Equatable {
    /// Buffers every frame until the consumer reads it.
    case unbounded
    /// Keeps only the newest `limit` frames when the consumer falls behind.
    ///
    /// Non-positive limits are treated as `1`.
    case bufferingNewest(Int)

    var streamPolicy: AsyncThrowingStream<MediaFrame, Error>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded:
            return .unbounded
        case .bufferingNewest(let limit):
            return .bufferingNewest(max(1, limit))
        }
    }
}

/// Options for subscribing to a compressed media track.
public struct MediaTrackOptions: Sendable, Equatable {
    /// Buffering behavior for delivered frames.
    public let bufferingPolicy: MediaTrackBufferingPolicy

    public init(
        bufferingPolicy: MediaTrackBufferingPolicy = .unbounded
    ) {
        self.bufferingPolicy = bufferingPolicy
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

/// Advanced low-level subscription to one MoQ media track.
///
/// `MediaTrack` surfaces raw ``MediaFrame`` values from the relay so you can plug them into
/// your own decoder or processing pipeline. In most apps, use ``Player`` instead, because
/// it manages subscriptions, decoding, buffering, and rendering for you.
///
/// ``frames`` is an `AsyncThrowingStream` that completes when the track ends or throws when
/// the underlying media subscription fails. ``state`` mirrors the same lifecycle for consumers
/// that prefer state events.
public final class MediaTrack: @unchecked Sendable {
    /// A stream of raw media frames as they arrive from the relay.
    public let frames: AsyncThrowingStream<MediaFrame, Error>
    /// A stream of ``MediaTrackState`` transitions. Always yields `.idle` as its first element.
    public let state: AsyncStream<MediaTrackState>

    private let media: MediaFrameStream
    private let framesContinuation: AsyncThrowingStream<MediaFrame, Error>.Continuation
    private let stateContinuation: AsyncStream<MediaTrackState>.Continuation
    private var readTask: Task<Void, Never>?

    init(
        media: MediaFrameStream,
        options: MediaTrackOptions = MediaTrackOptions()
    ) {
        self.media = media

        var framesCont: AsyncThrowingStream<MediaFrame, Error>.Continuation!
        let framesStream = AsyncThrowingStream<MediaFrame, Error>(
            bufferingPolicy: options.bufferingPolicy.streamPolicy
        ) { framesCont = $0 }

        var stateCont: AsyncStream<MediaTrackState>.Continuation!
        let stateStream = AsyncStream<MediaTrackState> { stateCont = $0 }

        self.frames = framesStream
        self.state = stateStream
        self.framesContinuation = framesCont
        self.stateContinuation = stateCont

        stateCont.yield(.idle)

        readTask = Task.detached {
            var isFirstFrame = true
            var didFinishFrames = false
            defer {
                if !didFinishFrames {
                    framesCont.finish()
                }
                stateCont.finish()
            }

            do {
                for try await frame in media.frames {
                    guard !Task.isCancelled else { return }
                    if isFirstFrame {
                        stateCont.yield(.active)
                        isFirstFrame = false
                    }
                    framesCont.yield(frame)
                }

                if !Task.isCancelled {
                    stateCont.yield(.closed)
                }
            } catch {
                if !Task.isCancelled {
                    stateCont.yield(.error(error.localizedDescription))
                    framesCont.finish(throwing: error)
                    didFinishFrames = true
                }
            }
        }
    }

    /// Cancels the track subscription and completes both ``frames`` and ``state`` streams.
    ///
    /// Safe to call multiple times.
    public func close() {
        media.close()
        readTask?.cancel()
        readTask = nil
        // Do not yield .closed here — the read task's defer handles that on a normal
        // end, and double-yielding would emit two .closed events to state consumers.
        stateContinuation.finish()
        framesContinuation.finish()
    }

    deinit {
        media.close()
        readTask?.cancel()
        stateContinuation.finish()
        framesContinuation.finish()
    }
}
