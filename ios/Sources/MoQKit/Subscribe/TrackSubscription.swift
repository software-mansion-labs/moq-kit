import Foundation
import Moq

// MARK: - TrackDelivery

/// How raw MoQ track groups should be delivered.
public enum TrackDelivery: Sendable, Equatable {
    /// Delivers groups with monotonically increasing sequence numbers.
    ///
    /// Late groups whose sequence number is lower than or equal to a group already delivered
    /// are skipped.
    case monotonic
    /// Delivers groups in arrival order.
    ///
    /// Sequence numbers may move backwards if older groups arrive after newer ones.
    case arrival
}

// MARK: - TrackObject

/// A raw object received from a MoQ track.
public struct TrackObject: Sendable {
    /// The object's payload bytes.
    public let payload: Data
    /// The sequence number of the MoQ group that contained this object.
    public let groupSequence: UInt64
    /// The zero-based index of this object within its group.
    public let objectIndex: UInt64
}

// MARK: - TrackSubscription

private final class TrackSubscriptionState: @unchecked Sendable {
    private let lock = UnfairLock()
    private var closed = false
    private var readTask: Task<Void, Never>?
    private var currentGroup: Moq.GroupConsumer?
    private var track: Moq.TrackConsumer?

    func setTrack(_ track: Moq.TrackConsumer) -> Bool {
        let shouldCancel = lock.withLock {
            if closed {
                return true
            }
            self.track = track
            return false
        }

        if shouldCancel {
            track.cancel()
            return false
        }

        return true
    }

    func setReadTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if closed {
                return true
            }
            readTask = task
            return false
        }

        if shouldCancel {
            task.cancel()
        }
    }

    func close() -> (task: Task<Void, Never>?, group: Moq.GroupConsumer?, track: Moq.TrackConsumer?)? {
        lock.withLock {
            guard !closed else { return nil }
            closed = true
            let task = readTask
            let group = currentGroup
            let track = self.track
            readTask = nil
            currentGroup = nil
            self.track = nil
            return (task, group, track)
        }
    }

    func setCurrentGroup(_ group: Moq.GroupConsumer) -> Bool {
        let shouldCancel = lock.withLock {
            if closed {
                return true
            }
            currentGroup = group
            return false
        }

        if shouldCancel {
            group.cancel()
            return false
        }

        return true
    }

    func clearCurrentGroup(_ group: Moq.GroupConsumer) {
        lock.withLock {
            if currentGroup === group {
                currentGroup = nil
            }
        }
    }
}

/// A subscription to a raw MoQ track.
///
/// Unlike ``MediaTrack``, this reads unparsed MoQ objects and does not require the track to
/// appear in a broadcast catalog.
public final class TrackSubscription: @unchecked Sendable {
    /// Emits raw objects from the track until the track ends, ``close()`` is called, or an
    /// underlying subscription error occurs.
    public let objects: AsyncThrowingStream<TrackObject, Error>

    private let retainedBroadcast: Moq.BroadcastConsumer
    private let continuation: AsyncThrowingStream<TrackObject, Error>.Continuation
    private let state = TrackSubscriptionState()

    init(broadcast: Moq.BroadcastConsumer, name: String, delivery: TrackDelivery) throws {
        self.retainedBroadcast = broadcast

        var pendingContinuation: AsyncThrowingStream<TrackObject, Error>.Continuation?
        self.objects = AsyncThrowingStream { pendingContinuation = $0 }
        guard let continuation = pendingContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        self.continuation = continuation

        continuation.onTermination = { [weak self] _ in
            self?.close()
        }

        let state = self.state
        let readTask = Task.detached { [broadcast, continuation, state] in
            await Self.readObjects(
                from: broadcast,
                name: name,
                delivery: delivery,
                state: state,
                continuation: continuation
            )
        }
        state.setReadTask(readTask)
    }

    /// Cancels the track subscription and completes the object stream.
    ///
    /// Safe to call multiple times.
    public func close() {
        guard let resources = state.close() else { return }

        resources.track?.cancel()
        resources.group?.cancel()
        resources.task?.cancel()
        continuation.finish()
    }

    deinit {
        close()
    }

    private static func readObjects(
        from broadcast: Moq.BroadcastConsumer,
        name: String,
        delivery: TrackDelivery,
        state: TrackSubscriptionState,
        continuation: AsyncThrowingStream<TrackObject, Error>.Continuation
    ) async {
        do {
            let track = try await broadcast.subscribeTrack(name: name, subscription: nil)
            guard state.setTrack(track) else {
                continuation.finish()
                return
            }

            while !Task.isCancelled {
                let group: Moq.GroupConsumer?
                switch delivery {
                case .monotonic:
                    group = try await track.nextGroup()
                case .arrival:
                    group = try await track.recvGroup()
                }

                guard let group else {
                    continuation.finish()
                    return
                }

                guard state.setCurrentGroup(group) else {
                    continuation.finish()
                    return
                }
                defer {
                    state.clearCurrentGroup(group)
                    group.cancel()
                }

                let sequence = group.sequence
                var objectIndex: UInt64 = 0

                while !Task.isCancelled {
                    guard let frame = try await group.readFrame() else {
                        break
                    }
                    continuation.yield(
                        TrackObject(
                            payload: frame.payload,
                            groupSequence: sequence,
                            objectIndex: objectIndex
                        )
                    )
                    objectIndex += 1
                }
            }

            continuation.finish()
        } catch MoqError.Cancelled {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
