import Foundation
import os

extension PipelineEvent {
    var shouldLogFrameDrop: Bool {
        guard case .frameDropped(_, _, let reason, _, _, _, _) = self else {
            return false
        }
        // Temporarily mute these high-volume policy drops while keeping their typed
        // diagnostics available to PipelineBus observers and diagnostics streams.
        return reason != .staleVsPlayback && reason != .backlogOverflow
    }

    var frameDropLogDescription: String? {
        guard case .frameDropped(
            let context,
            let stage,
            let reason,
            let ptsUs,
            let groupSequence,
            let count,
            let bytes
        ) = self else {
            return nil
        }
        let diagnostics = context.dropDiagnostics

        return "Frame dropped "
            + "track=\(context.trackId), "
            + "media=\(context.mediaKind), "
            + "stage=\(stage), "
            + "reason=\(reason), "
            + "pts=\(ptsUs.map(Self.formatTimestamp) ?? "nil"), "
            + "groupSequence=\(groupSequence.map(String.init) ?? "nil"), "
            + "count=\(count), "
            + "bytes=\(bytes), "
            + "playhead=\(diagnostics?.playheadUs.map(Self.formatTimestamp) ?? "nil"), "
            + "decision=\(diagnostics.map(Self.formatDecision) ?? "nil"), "
            + "bufferBefore=\(diagnostics?.bufferDepthBefore.map(Self.formatDepth) ?? "nil"), "
            + "bufferAfter=\(diagnostics?.bufferDepthAfter.map(Self.formatDepth) ?? "nil"), "
            + "limits=\(diagnostics?.bufferLimits.map(Self.formatLimits) ?? "nil"), "
            + "timestampNanos=\(context.timestampNanos)"
    }

    private static func formatDecision(_ diagnostics: FrameDropDiagnostics) -> String {
        switch diagnostics.decision {
        case .backlogOverflow(let exceededLimits):
            guard !exceededLimits.isEmpty else {
                return "bounded buffer eviction"
            }
            let names = exceededLimits.map { limit in
                switch limit {
                case .frames: return "frames"
                case .bytes: return "bytes"
                case .duration: return "duration"
                }
            }
            return "buffer capacity exceeded (\(names.joined(separator: ", ")))"
        case .staleVsPlayback(
            let reference,
            let referenceTimestampUs,
            let timestampDeltaUs,
            let toleranceUs
        ):
            let referenceName: String
            switch reference {
            case .playhead: referenceName = "playhead"
            case .targetPlayback: referenceName = "target playback"
            case .audioReadCursor: referenceName = "audio read cursor"
            }
            let latenessUs = timestampDeltaUs < 0 ? timestampDeltaUs.magnitude : 0
            var result = "frame is \(formatDuration(latenessUs)) behind \(referenceName)"
                + " (\(formatTimestamp(referenceTimestampUs)))"
            if let toleranceUs {
                let exceededUs = latenessUs > toleranceUs ? latenessUs - toleranceUs : 0
                result += "; allowed lateness=\(formatDuration(toleranceUs))"
                    + "; exceeded by=\(formatDuration(exceededUs))"
            }
            return result
        }
    }

    private static func formatTimestamp(_ timestampUs: Int64) -> String {
        let sign = timestampUs < 0 ? "-" : ""
        let value = timestampUs.magnitude
        let hours = value / 3_600_000_000
        let minutes = (value / 60_000_000) % 60
        let seconds = (value / 1_000_000) % 60
        let microseconds = value % 1_000_000
        return String(
            format: "%@%02llu:%02llu:%02llu.%06llu",
            sign, hours, minutes, seconds, microseconds
        )
    }

    private static func formatDuration(_ durationUs: UInt64) -> String {
        if durationUs >= 1_000_000 {
            let seconds = durationUs / 1_000_000
            let remainderUs = durationUs % 1_000_000
            if remainderUs.isMultiple(of: 1_000) {
                return String(
                    format: "%llu.%03llus",
                    seconds,
                    remainderUs / 1_000
                )
            }
            return String(format: "%llu.%06llus", seconds, remainderUs)
        }
        if durationUs >= 1_000 {
            return durationUs.isMultiple(of: 1_000)
                ? "\(durationUs / 1_000)ms"
                : String(format: "%.3fms", Double(durationUs) / 1_000)
        }
        return "\(durationUs)µs"
    }

    private static func formatDepth(_ depth: BufferDepth) -> String {
        "\(depth.frames) frames/\(formatBytes(depth.bytes))/\(formatDuration(depth.durationUs))"
    }

    private static func formatLimits(_ limits: BufferLimits) -> String {
        "\(limits.maxFrames) frames/\(formatBytes(limits.maxBytes))"
            + "/\(formatDuration(limits.maxDurationUs))"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
        }
        if bytes >= 1_024 {
            return String(format: "%.1f KiB", Double(bytes) / 1_024)
        }
        return "\(bytes) B"
    }
}

final class PipelineObserverHandle: @unchecked Sendable {
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
    func observe(
        _ observer: @escaping @Sendable (PipelineEvent) -> Void
    ) -> PipelineObserverHandle {
        let id = UUID()
        lock.withLock {
            observers[id] = observer
        }
        return PipelineObserverHandle { [weak self] in
            self?.removeObserver(id)
        }
    }

    func emit(_ event: PipelineEvent) {
        if event.shouldLogFrameDrop,
           let dropDescription = event.frameDropLogDescription
        {
            KitLogger.player.debug("\(dropDescription, privacy: .public)")
        }

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
