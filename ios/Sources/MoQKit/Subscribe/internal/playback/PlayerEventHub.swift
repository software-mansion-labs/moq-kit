import Foundation

final class PlayerEventHub: @unchecked Sendable {
    typealias Listener = @Sendable (PlayerEvent) -> Void

    private let lock = UnfairLock()
    private let clock: ContinuousClock
    private var listeners: [UUID: Listener] = [:]
    private var sequence: UInt64 = 0

    init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }

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
    func emit(_ type: PlayerEventType) -> PlayerEvent {
        let timestamp = clock.now
        let result: (PlayerEvent, [Listener]) = lock.withLock {
            sequence = sequence &+ 1
            let event = PlayerEvent(
                type: type,
                timestamp: timestamp,
                sequence: sequence
            )
            return (event, Array(listeners.values))
        }

        for listener in result.1 {
            listener(result.0)
        }
        return result.0
    }
}

extension MediaFrameKind {
    var playerTrackKind: PlayerTrackKind {
        switch self {
        case .audio:
            return .audio
        case .video:
            return .video
        }
    }
}
