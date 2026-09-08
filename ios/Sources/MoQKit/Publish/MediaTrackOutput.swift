import Foundation
import Moq

/// One encoder generation. Closing it fences late output before removing its catalog entry.
final class MediaTrackOutput {
    private let lock = NSLock()
    private var closed = false
    private var producer: Moq.MediaProducer?
    private let broadcast: Moq.BroadcastProducer
    private let format: String
    private let onActive: () -> Void
    private let onError: (Error) -> Void

    init(broadcast: Moq.BroadcastProducer, format: String,
         onActive: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.broadcast = broadcast
        self.format = format
        self.onActive = onActive
        self.onError = onError
    }

    func write(_ data: Data, initData: Data?, timestampUs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            if producer == nil {
                guard let initData else { return }
                producer = try broadcast.publishMedia(format: format, initData: initData)
                onActive()
            }
            try producer?.writeFrame(data, timestampUs: timestampUs)
        } catch {
            closed = true
            try? producer?.finish()
            producer = nil
            onError(error)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? producer?.finish()
        producer = nil
        onError(error)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        try? producer?.finish()
        producer = nil
    }
}
