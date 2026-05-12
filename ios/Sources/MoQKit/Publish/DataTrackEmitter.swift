import Foundation
import MoQKitFFI

/// Push-based source for publishing app-defined binary messages on an object track.
///
/// Create one emitter per published data track, hand it to ``Publisher/addDataTrack(name:source:)``,
/// then keep a reference and call ``send(_:)`` whenever your app has a new payload.
public final class DataTrackEmitter: @unchecked Sendable {
    private var producer: MoqTrackProducer?
    private var stopped = false

    /// Creates an emitter that can be attached to a published data track.
    public init() {}

    internal func attach(_ producer: MoqTrackProducer) {
        self.producer = producer
    }

    internal func detach() {
        stopped = true
        producer = nil
    }

    /// Publishes one object on the track.
    ///
    /// If the track has not started yet, or has already stopped, this is a no-op.
    public func send(_ data: Data) throws {
        guard !stopped, let producer else { return }
        try producer.writeFrame(payload: data)
    }
}
