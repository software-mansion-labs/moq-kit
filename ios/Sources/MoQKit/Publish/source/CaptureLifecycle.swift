import Foundation

/// Serial control executor shared by capture and publication. Frame callbacks never wait on it.
enum PublishControl {
    private static let key = DispatchSpecificKey<Bool>()
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.swmansion.MoQKit.publish-control")
        queue.setSpecific(key: key, value: true)
        return queue
    }()

    static func sync<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) == true { return try action() }
        return try queue.sync(execute: action)
    }

    static func run<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try action() }) }
        }
    }

    static func finish(_ action: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async { action(); continuation.resume() }
        }
    }
}

/// Replays availability and delivers every transition on PublishControl.
final class CaptureLifecycle {
    struct Snapshot {
        var running = false
        var closed = false
        var generation: UInt64 = 0
    }
    private(set) var snapshot = Snapshot()
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    private var owner: UUID?

    func reserve(_ id: UUID) throws {
        guard !snapshot.closed else { throw SessionError.alreadyClosed }
        guard owner == nil else {
            throw SessionError.invalidConfiguration("Capture already has a publication attachment")
        }
        owner = id
    }

    func release(_ id: UUID) {
        if owner == id { owner = nil }
    }

    func setRunning(_ value: Bool) {
        guard !snapshot.closed, snapshot.running != value else { return }
        snapshot.running = value
        if value { snapshot.generation &+= 1 }
        notify()
    }

    func close() {
        guard !snapshot.closed else { return }
        snapshot.running = false
        snapshot.closed = true
        notify()
        observers.removeAll()
        owner = nil
    }

    private func notify() {
        for observer in Array(observers.values) { observer(snapshot) }
    }

    func observe(_ observer: @escaping (Snapshot) -> Void) -> () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return { [weak self] in self?.observers[id] = nil }
    }
}

/// All resource transitions for one media publication pass through reconcile().
final class CaptureTrackBinding {
    private var closed = false
    private var enabled: Bool
    private var source = CaptureLifecycle.Snapshot(running: true)
    private var generation: UInt64?
    private var stopEncoding: (() -> Void)?
    private var cancelObservation: (() -> Void)?
    private let startEncoding: () throws -> () -> Void
    private let onState: (PublishedTrackState) -> Void
    private let onError: (Error) -> Void
    private let onClosed: () -> Void
    private(set) var failure: Error?

    init(enabled: Bool, start: @escaping () throws -> () -> Void,
         onState: @escaping (PublishedTrackState) -> Void,
         onError: @escaping (Error) -> Void, onClosed: @escaping () -> Void) {
        self.enabled = enabled
        startEncoding = start
        self.onState = onState
        self.onError = onError
        self.onClosed = onClosed
    }

    func attach(to lifecycle: CaptureLifecycle?) throws {
        if let lifecycle {
            let cancel = lifecycle.observe { [weak self] snapshot in
                guard let self, !self.closed else { return }
                if snapshot.generation != self.source.generation { self.failure = nil }
                self.source = snapshot
                self.reconcile()
            }
            if closed { cancel() } else { cancelObservation = cancel }
        } else { reconcile() }
        if let failure { throw failure }
    }

    func setEnabled(_ value: Bool) throws {
        guard !closed else { throw SessionError.alreadyClosed }
        enabled = value
        failure = nil
        reconcile()
        if let failure { throw failure }
    }

    func fail(_ error: Error) {
        guard !closed else { return }
        stopOutput()
        failure = error
        onState(.failed(error.localizedDescription))
        onError(error)
    }

    private func reconcile() {
        guard !closed else { return }
        if source.closed { stop(); onClosed(); return }
        if !enabled || !source.running {
            stopOutput()
            onState(enabled ? .idle : .disabled)
            return
        }
        if generation != source.generation { stopOutput() }
        guard stopEncoding == nil, failure == nil else { return }
        do {
            onState(.starting)
            stopEncoding = try startEncoding()
            generation = source.generation
        } catch { fail(error) }
    }

    private func stopOutput() {
        let stop = stopEncoding
        stopEncoding = nil
        generation = nil
        stop?()
    }

    func stop() {
        guard !closed else { return }
        closed = true
        stopOutput()
        cancelObservation?()
        cancelObservation = nil
    }
}

/// Fences encoder input against teardown without holding a lock while draining the codec.
final class CaptureFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func send(_ encode: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        encode()
        return true
    }

    func close(_ stop: () -> Void) {
        lock.lock()
        closed = true
        lock.unlock()
        stop()
    }
}
