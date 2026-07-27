import Foundation
import MoqFFI

// MARK: - Media Frame Stream

final class MediaFrameStream: @unchecked Sendable {
    let frames: AsyncThrowingStream<MediaFrame, Error>

    private let lock = UnfairLock()
    private let closeHandler: @Sendable () -> Void
    private var closed = false

    init(
        frames: AsyncThrowingStream<MediaFrame, Error>,
        close: @escaping @Sendable () -> Void
    ) {
        self.frames = frames
        self.closeHandler = close
    }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }

        guard shouldClose else { return }
        closeHandler()
    }

    deinit {
        close()
    }
}

// MARK: - Media Subscription Registry

struct MediaSubscriptionKey: Hashable, Sendable {
    let name: String
    let container: MoqContainer

    init(_ request: MediaTrackRequest) {
        self.name = request.name
        self.container = request.container.rawContainer
    }
}

final class MediaSubscriptionRegistry: @unchecked Sendable {
    private let lock = UnfairLock()
    private let broadcast: any MoqBroadcastConsumerProtocol
    private var hubs: [MediaSubscriptionKey: MediaFrameHub] = [:]

    var activeSubscriptionCount: Int {
        lock.withLock { hubs.count }
    }

    init(broadcast: any MoqBroadcastConsumerProtocol) {
        self.broadcast = broadcast
    }

    /// Returns a downstream compressed-frame stream for a media track.
    ///
    /// The first subscriber for a key creates the upstream MoQ media subscription and chooses
    /// its `maxLatencyMs`; later subscribers share those compressed frames while keeping their
    /// own decoder/renderer/processor state.
    func subscribeMedia(
        _ request: MediaTrackRequest,
        bufferingPolicy: MediaTrackBufferingPolicy = .unbounded
    ) throws -> MediaFrameStream {
        let key = MediaSubscriptionKey(request)

        let result: Result<MediaFrameStream, Error> = lock.withLock {
            if let existing = hubs[key] {
                if let stream = existing.subscribe(bufferingPolicy: bufferingPolicy) {
                    return .success(stream)
                }
                hubs[key] = nil
            }

            let created = MediaFrameHub(
                subscribe: { [broadcast] in
                    try await broadcast.subscribeMedia(
                        name: request.name,
                        container: request.container.rawContainer,
                        subscription: MoqSubscription(
                            latencyMaxMs: request.targetBuffering.millisecondsUInt64Clamped)
                    )
                }
            ) { [weak self] hub in
                self?.removeHub(key, matching: hub)
            }
            hubs[key] = created

            guard let stream = created.subscribe(bufferingPolicy: bufferingPolicy) else {
                hubs[key] = nil
                preconditionFailure("Newly created MediaFrameHub was unexpectedly finished")
            }
            return .success(stream)
        }
        return try result.get()
    }

    private func removeHub(_ key: MediaSubscriptionKey, matching hub: MediaFrameHub) {
        lock.withLock {
            guard hubs[key] === hub else { return }
            hubs[key] = nil
        }
    }
}

// MARK: - Media Frame Hub

fileprivate final class MediaFrameHub: @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<MediaFrame, Error>.Continuation
    fileprivate typealias FinishHandler = @Sendable (MediaFrameHub) -> Void
    fileprivate typealias Subscribe = @Sendable () async throws -> any MoqMediaConsumerProtocol

    // The (async) upstream subscribe runs on the shared read task; subscribers are
    // created from non-async contexts.
    private let subscribe: Subscribe
    private let onFinished: FinishHandler
    private let lock = UnfairLock()

    private var consumer: (any MoqMediaConsumerProtocol)?
    private var continuations: [UUID: Continuation] = [:]
    private var readTask: Task<Void, Never>?
    private var finished = false

    fileprivate init(
        subscribe: @escaping Subscribe,
        onFinished: @escaping FinishHandler
    ) {
        self.subscribe = subscribe
        self.onFinished = onFinished
    }

    func subscribe(bufferingPolicy: MediaTrackBufferingPolicy) -> MediaFrameStream? {
        let id = UUID()
        var pendingContinuation: Continuation?
        let frames = AsyncThrowingStream<MediaFrame, Error>(
            bufferingPolicy: bufferingPolicy.streamPolicy
        ) { continuation in
            pendingContinuation = continuation
        }
        guard let continuation = pendingContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }

        let stream = MediaFrameStream(frames: frames) { [weak self] in
            self?.removeSubscriber(id)
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }

        let didSubscribe = lock.withLock { () -> Bool in
            guard !finished else {
                return false
            }

            continuations[id] = continuation
            guard readTask == nil else { return true }

            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.readFrames()
            }
            readTask = task
            return true
        }

        guard didSubscribe else {
            continuation.finish()
            return nil
        }

        return stream
    }

    deinit {
        finishAll(throwing: nil, cancelUpstream: true)
    }

    private func readFrames() async {
        do {
            let consumer = try await subscribe()
            let alreadyFinished = lock.withLock { () -> Bool in
                guard !finished else { return true }
                self.consumer = consumer
                return false
            }
            if alreadyFinished {
                consumer.cancel()
                return
            }

            while !Task.isCancelled {
                guard let frame = try await consumer.next() else {
                    finishAll(throwing: nil, cancelUpstream: false)
                    return
                }
                guard !Task.isCancelled else { break }
                yield(MediaFrame(frame))
            }

            finishAll(throwing: nil, cancelUpstream: true)
        } catch MoqError.Cancelled {
            finishAll(throwing: nil, cancelUpstream: false)
        } catch {
            finishAll(throwing: error, cancelUpstream: true)
        }
    }

    private func currentConsumer() -> (any MoqMediaConsumerProtocol)? {
        lock.withLock { consumer }
    }

    private func yield(_ frame: MediaFrame) {
        let sinks = lock.withLock {
            Array(continuations.values)
        }
        sinks.forEach { $0.yield(frame) }
    }

    private func removeSubscriber(_ id: UUID) {
        let result = lock.withLock { () -> (
            continuation: Continuation?,
            shouldStop: Bool,
            task: Task<Void, Never>?
        ) in
            let continuation = continuations.removeValue(forKey: id)
            guard continuations.isEmpty, !finished else {
                return (continuation, false, nil)
            }

            finished = true
            let task = readTask
            readTask = nil
            return (continuation, true, task)
        }

        result.continuation?.finish()
        guard result.shouldStop else { return }

        currentConsumer()?.cancel()
        result.task?.cancel()
        onFinished(self)
    }

    private func finishAll(throwing error: Error?, cancelUpstream: Bool) {
        let result = lock.withLock { () -> (
            didFinish: Bool,
            continuations: [Continuation],
            task: Task<Void, Never>?
        ) in
            guard !finished else {
                return (false, [], nil)
            }

            finished = true
            let continuations = Array(self.continuations.values)
            self.continuations.removeAll()
            let task = readTask
            readTask = nil
            return (true, continuations, task)
        }

        guard result.didFinish else { return }

        if cancelUpstream {
            currentConsumer()?.cancel()
        }
        result.task?.cancel()

        for continuation in result.continuations {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }

        onFinished(self)
    }
}
