import Atomics
import Foundation

/// Gate that hands off the "first audible frame" context from the ingest side to the
/// audio render-event bridge. Internally synchronized — callers (notably
/// `PlaybackStatsTracker`) must not wrap these methods in an outer lock.
final class AudioPlaybackStartHandoff: @unchecked Sendable {
    private let lock = UnfairLock()
    private var pendingContext: PlaybackStartContext?

    /// Advisory atomic probe for the audio render callback to cheaply decide whether to
    /// dispatch to the bridge queue. The pending context itself is still protected by `lock`.
    private let isArmed = ManagedAtomic<Bool>(false)

    var hasPendingPlaybackStart: Bool {
        isArmed.load(ordering: .relaxed)
    }

    func prepare(_ context: PlaybackStartContext) {
        lock.withLock {
            pendingContext = context
            isArmed.store(true, ordering: .relaxed)
        }
    }

    func prepare(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        prepare(
            PlaybackStartContext(
                kind: .audio,
                trackName: trackName,
                sourceTimestampUs: sourceTimestampUs,
                targetBuffering: targetBuffering,
                trackEpoch: trackEpoch
            )
        )
    }

    func clear() {
        lock.withLock {
            pendingContext = nil
            isArmed.store(false, ordering: .relaxed)
        }
    }

    func consumeIfRendered(timestampUs: UInt64) -> PlaybackStartContext? {
        guard isArmed.load(ordering: .relaxed) else { return nil }
        return lock.withLock {
            guard let context = pendingContext,
                  timestampUs >= context.sourceTimestampUs
            else { return nil }
            pendingContext = nil
            isArmed.store(false, ordering: .relaxed)
            return context
        }
    }
}
