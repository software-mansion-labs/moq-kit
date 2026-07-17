import Foundation

final class PipelineObservation: @unchecked Sendable {
    private let lock = UnfairLock()
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }

    deinit {
        cancel()
    }
}

/// Per-player diagnostic event bus. Streams never replay and independently retain only
/// their newest bounded window so diagnostics cannot apply backpressure to media work.
final class PipelineBus: @unchecked Sendable {
    private typealias Continuation = AsyncStream<PipelineEvent>.Continuation

    private let capacity: Int
    private let lock = UnfairLock()
    private var continuations: [UUID: Continuation] = [:]
    private var observers: [UUID: @Sendable (PipelineEvent) -> Void] = [:]

    init(capacity: Int = 256) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    func events() -> AsyncStream<PipelineEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(capacity)) { continuation in
            lock.withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    @discardableResult
    func observe(_ observer: @escaping @Sendable (PipelineEvent) -> Void) -> PipelineObservation {
        let id = UUID()
        lock.withLock {
            observers[id] = observer
        }
        return PipelineObservation { [weak self] in
            self?.removeObserver(id)
        }
    }

    func emit(_ event: PipelineEvent) {
        let targets = lock.withLock {
            (Array(continuations.values), Array(observers.values))
        }
        targets.1.forEach { $0(event) }
        targets.0.forEach { $0.yield(event) }
    }

    func finish() {
        let targets = lock.withLock {
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        targets.forEach { $0.finish() }
    }

    private func removeContinuation(_ id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }

    private func removeObserver(_ id: UUID) {
        _ = lock.withLock {
            observers.removeValue(forKey: id)
        }
    }
}
