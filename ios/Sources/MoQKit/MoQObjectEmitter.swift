import Foundation
import MoQKitFFI

/// Push-based source for publishing raw binary objects on an object track.
///
/// Hold a reference to the emitter and call ``send(_:)`` to publish objects.
public final class MoQObjectEmitter: @unchecked Sendable {
    private var producer: MoqObjectProducer?
    private var stopped = false

    public init() {}

    internal func attach(_ producer: MoqObjectProducer) {
        self.producer = producer
    }

    internal func detach() {
        stopped = true
        producer = nil
    }

    /// Publish a single object. No-op if the track hasn't started or has stopped.
    public func send(_ data: Data) throws {
        guard !stopped, let producer else { return }
        try producer.writeObject(payload: data, endGroup: true)
    }
}
