import Foundation

final class PlayerEventHub: @unchecked Sendable {
    typealias Listener = @Sendable (PlayerEvent) -> Void

    private let lock = UnfairLock()
    private var listeners: [UUID: Listener] = [:]
    private var sequence: UInt64 = 0

    func subscribe(
        _ listener: @escaping @MainActor @Sendable (PlayerEvent) -> Void
    ) -> PlayerEventSubscription {
        subscribeInternal { event in
            Task { @MainActor in
                listener(event)
            }
        }
    }

    func subscribeInternal(
        _ listener: @escaping Listener
    ) -> PlayerEventSubscription {
        let id = UUID()
        lock.withLock {
            listeners[id] = listener
        }
        return PlayerEventSubscription { [weak self] in
            self?.lock.withLock {
                self?.listeners[id] = nil
            }
        }
    }

    @discardableResult
    func emit(
        _ name: PlayerEventName,
        attributes: [String: PlayerEventValue] = [:]
    ) -> PlayerEvent {
        let timestampMs = Self.timestampMs()
        let result: (PlayerEvent, [Listener]) = lock.withLock {
            sequence = sequence &+ 1
            let event = PlayerEvent(
                name: name,
                timestampMs: timestampMs,
                sequence: sequence,
                attributes: attributes
            )
            return (event, Array(listeners.values))
        }

        for listener in result.1 {
            listener(result.0)
        }
        return result.0
    }

    static func timestampMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }
}

// MARK: - Shared attribute builder

enum PlayerEventAttributes {
    static func track(
        kind: MediaFrameKind,
        trackName: String? = nil,
        message: String? = nil,
        isSwitch: Bool? = nil,
        sourceTimestampUs: UInt64? = nil,
        targetBufferingMs: UInt64? = nil,
        keyframe: Bool? = nil,
        payloadBytes: Int? = nil
    ) -> [String: PlayerEventValue] {
        var attributes: [String: PlayerEventValue] = ["kind": .string(kind.eventName)]
        if let trackName {
            attributes["trackName"] = .string(trackName)
        }
        if let message {
            attributes["message"] = .string(message)
        }
        if let isSwitch {
            attributes["isSwitch"] = .bool(isSwitch)
        }
        if let sourceTimestampUs {
            attributes["sourceTimestampUs"] = .uint(sourceTimestampUs)
        }
        if let targetBufferingMs {
            attributes["targetBufferingMs"] = .uint(targetBufferingMs)
        }
        if let keyframe {
            attributes["keyframe"] = .bool(keyframe)
        }
        if let payloadBytes {
            attributes["payloadBytes"] = .uint(UInt64(max(0, payloadBytes)))
        }
        return attributes
    }
}
