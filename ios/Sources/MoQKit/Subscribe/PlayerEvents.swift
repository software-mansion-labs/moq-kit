import Foundation

// MARK: - PlayerEvent

/// Stable event names emitted by ``Player/subscribeEvents(_:)``.
///
/// Events represent transitions in the player's lifecycle. Periodic samples (bitrate,
/// latency, buffer fill, fps) are not events — subscribe to ``Player/subscribeStats(_:)``
/// for those.
public enum PlayerEventName: String, Sendable {
    case playerInit = "player.init"
    case playerDestroy = "player.destroy"
    case playbackRequest = "playback.request"
    case playbackStart = "playback.start"
    case playbackPause = "playback.pause"
    case playbackResume = "playback.resume"
    case playbackEnd = "playback.end"
    case trackSubscribeStart = "track.subscribe.start"
    case trackReady = "track.ready"
    case trackPlaying = "track.playing"
    case trackSubscribeError = "track.subscribe.error"
    case trackSubscribeEnd = "track.subscribe.end"
    case trackSelect = "track.select"
    case trackSwitch = "track.switch"
    case trackStallStart = "track.stall.start"
    case trackStallEnd = "track.stall.end"
    case rebufferStart = "rebuffer.start"
    case rebufferEnd = "rebuffer.end"
    case decodeError = "decode.error"
}

/// Media kind carried by player events.
public enum PlayerTrackKind: String, Sendable {
    case audio
    case video
}

/// Session-level context shared by player lifecycle events.
public struct PlayerSessionEvent: Sendable {
    public let catalogPath: String
    public let targetBuffering: Duration
    public let videoTrackName: String?
    public let audioTrackName: String?
}

/// Track reference shared by track lifecycle events.
public struct PlayerTrackEvent: Sendable {
    public let kind: PlayerTrackKind
    public let trackName: String?
    public let epoch: UInt64

    public init(kind: PlayerTrackKind, trackName: String? = nil, epoch: UInt64 = .zero) {
        self.kind = kind
        self.trackName = trackName
        self.epoch = epoch
    }
}

/// Selected-track state after a selection change.
public struct PlayerTrackSelectionEvent: Sendable {
    public let kind: PlayerTrackKind
    public let trackName: String?

    public var isEnabled: Bool {
        trackName != nil
    }
}

/// First accepted/decoded frame for a subscribed track.
public struct PlayerTrackReadyEvent: Sendable {
    public let track: PlayerTrackEvent
    public let sourceTimestampUs: UInt64
    public let targetBuffering: Duration
    public let keyframe: Bool
    public let payloadBytes: UInt64
}

/// First audible or visible playback for a subscribed track.
public struct PlayerTrackPlayingEvent: Sendable {
    public let track: PlayerTrackEvent
    public let sourceTimestampUs: UInt64
    public let targetBuffering: Duration
    public let output: PlayerTrackPlaybackOutput
}

public enum PlayerTrackPlaybackOutput: Sendable {
    case audio(PlayerAudioPlaybackOutput)
    case video(PlayerVideoPlaybackOutput)
}

public struct PlayerAudioPlaybackOutput: Sendable {
    public let timestampUs: UInt64
    public let hostTime: UInt64?
}

public struct PlayerVideoPlaybackOutput: Sendable {
    public let presentationTimeUs: UInt64
    public let clockTimeUs: UInt64
    public let buffer: Duration
}

/// Error associated with a specific track.
public struct PlayerTrackErrorEvent: Sendable {
    public let track: PlayerTrackEvent
    public let message: String
}

/// Playback end context.
public struct PlayerPlaybackEndEvent: Sendable {
    public let reason: String?
}

/// Strongly typed payload for each player event.
public enum PlayerEventType: Sendable {
    case playerInit(PlayerSessionEvent)
    case playerDestroy
    case playbackRequest(PlayerSessionEvent)
    case playbackStart(PlayerTrackPlayingEvent)
    case playbackPause(PlayerSessionEvent)
    case playbackResume(PlayerSessionEvent)
    case playbackEnd(PlayerPlaybackEndEvent)
    case trackSubscribeStart(PlayerTrackEvent)
    case trackReady(PlayerTrackReadyEvent)
    case trackPlaying(PlayerTrackPlayingEvent)
    case trackSubscribeError(PlayerTrackErrorEvent)
    case trackSubscribeEnd(PlayerTrackEvent)
    case trackSelect(PlayerTrackSelectionEvent)
    case trackSwitch(PlayerTrackEvent)
    case trackStallStart(PlayerTrackEvent)
    case trackStallEnd(PlayerTrackEvent)
    case rebufferStart(PlayerTrackEvent)
    case rebufferEnd(PlayerTrackEvent)
    case decodeError(PlayerTrackErrorEvent)

    public var name: PlayerEventName {
        switch self {
        case .playerInit:
            return .playerInit
        case .playerDestroy:
            return .playerDestroy
        case .playbackRequest:
            return .playbackRequest
        case .playbackStart:
            return .playbackStart
        case .playbackPause:
            return .playbackPause
        case .playbackResume:
            return .playbackResume
        case .playbackEnd:
            return .playbackEnd
        case .trackSubscribeStart:
            return .trackSubscribeStart
        case .trackReady:
            return .trackReady
        case .trackPlaying:
            return .trackPlaying
        case .trackSubscribeError:
            return .trackSubscribeError
        case .trackSubscribeEnd:
            return .trackSubscribeEnd
        case .trackSelect:
            return .trackSelect
        case .trackSwitch:
            return .trackSwitch
        case .trackStallStart:
            return .trackStallStart
        case .trackStallEnd:
            return .trackStallEnd
        case .rebufferStart:
            return .rebufferStart
        case .rebufferEnd:
            return .rebufferEnd
        case .decodeError:
            return .decodeError
        }
    }
}

/// A player event envelope.
public struct PlayerEvent: Sendable {
    public let type: PlayerEventType
    public let timestamp: ContinuousClock.Instant
    public let sequence: UInt64

    public var name: PlayerEventName {
        type.name
    }

    init(
        type: PlayerEventType,
        timestamp: ContinuousClock.Instant,
        sequence: UInt64
    ) {
        self.type = type
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// A cancellable event or stats subscription.
public final class PlayerEventSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        cancel()
    }

    public func cancel() {
        let action: (() -> Void)? = lock.withLock {
            let action = onCancel
            onCancel = nil
            return action
        }
        action?()
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
