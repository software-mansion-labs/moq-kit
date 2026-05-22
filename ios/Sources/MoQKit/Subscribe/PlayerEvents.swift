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
    case trackSubscribeReady = "track.subscribe.ready"
    case trackFrameReady = "track.frame.ready"
    case trackPlaying = "track.playing"
    case trackSubscribeError = "track.subscribe.error"
    case trackSubscribeEnd = "track.subscribe.end"
    case trackSelect = "track.select"
    case qualityChange = "quality.change"
    case trackStallStart = "track.stall.start"
    case trackStallEnd = "track.stall.end"
    case rebufferStart = "rebuffer.start"
    case rebufferEnd = "rebuffer.end"
    case decodeError = "decode.error"
}

/// Primitive event attribute value.
public enum PlayerEventValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
}

/// A player event envelope.
public struct PlayerEvent: Sendable {
    public let name: PlayerEventName
    public let timestampMs: Double
    public let sequence: UInt64
    public let attributes: [String: PlayerEventValue]

    init(
        name: PlayerEventName,
        timestampMs: Double,
        sequence: UInt64,
        attributes: [String: PlayerEventValue]
    ) {
        self.name = name
        self.timestampMs = timestampMs
        self.sequence = sequence
        self.attributes = attributes
    }
}

public extension PlayerEvent {
    /// Convenience accessor for a string attribute.
    func string(_ key: String) -> String? {
        guard case .string(let value) = attributes[key] else { return nil }
        return value
    }

    /// Convenience accessor for a bool attribute.
    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = attributes[key] else { return nil }
        return value
    }

    /// Convenience accessor for an unsigned integer attribute.
    func uint(_ key: String) -> UInt64? {
        guard case .uint(let value) = attributes[key] else { return nil }
        return value
    }

    /// Convenience accessor for a double attribute.
    func double(_ key: String) -> Double? {
        guard case .double(let value) = attributes[key] else { return nil }
        return value
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
