import Foundation

// MARK: - JitterBuffer

/// Generic sorted buffer with buffering/playing states for jitter resilience.
///
/// **Not thread-safe.** All access must be serialised by the owner (e.g. `VideoRendererTrack`).
///
/// `insert(item:timestampUs:)` returns `true` when the caller should fire a data-available
/// notification: either on the buffering→playing transition, or when inserting into an
/// empty buffer that is already playing.
final class JitterBuffer<T> {
    enum State {
        case buffering
        case pending
        case playing
    }

    struct Entry {
        let timestampUs: UInt64
        let item: T
    }

    private var targetBufferingUs: UInt64
    private var maxOffset: Int64?
    private var entries: [Entry] = []
    private var mode: State = .buffering
    private let wallClock: any PlaybackWallClock

    init(
        targetBufferingUs: UInt64,
        wallClock: any PlaybackWallClock = HostPlaybackWallClock()
    ) {
        self.targetBufferingUs = targetBufferingUs
        self.wallClock = wallClock
    }

    /// Insert an item sorted by timestamp. Returns `true` if the caller should fire
    /// a data-available notification (buffering→playing transition, or first item while playing).
    @discardableResult
    func insert(item: T, timestampUs: UInt64) -> Bool {
        guard let signedTimestamp = Self.signedTimestamp(timestampUs) else { return false }
        let result = signedTimestamp.subtractingReportingOverflow(wallClock.now(in: .us))
        guard !result.overflow else { return false }
        maxOffset = max(maxOffset ?? Int64.min, result.partialValue)

        let wasEmpty = entries.isEmpty
        let entry = Entry(timestampUs: timestampUs, item: item)

        let index = entries.firstIndex(where: { $0.timestampUs > timestampUs }) ?? entries.endIndex
        entries.insert(entry, at: index)

        // Transition buffering → playing when we have enough depth
        if mode == .buffering, updateBufferingStateIfReady() {
            return true
        }

        // Notify if inserting into empty buffer while playing
        return wasEmpty && mode == .playing
    }

    /// Dequeue the oldest entry. Returns `(nil, false)` when buffering or empty.
    /// Returns `(entry, false)` for frames that should be decoded but not displayed.
    func dequeue() -> (Entry?, Bool) {
        guard mode == .playing, !entries.isEmpty else { return (nil, false) }

        let entry = entries.removeFirst()

        let playable = targetPlaybackPTS().map { entry.timestampUs >= $0 } ?? true
        return (entry, playable)
    }

    /// Peek at the oldest entry without removing it. Returns nil when empty.
    func peekFront() -> Entry? {
        entries.first
    }

    /// Update the target buffering depth.
    @discardableResult
    func updateTargetBuffering(us: UInt64) -> Bool {
        targetBufferingUs = us
        guard mode == .buffering else { return false }
        return updateBufferingStateIfReady()
    }

    /// Clear all entries and reset to buffering state.
    func flush() {
        entries.removeAll()
        mode = .buffering
    }

    /// Returns the PTS of the first entry satisfying `predicate`, without removing it.
    func firstPts(where predicate: (Entry) -> Bool) -> UInt64? {
        entries.first(where: predicate)?.timestampUs
    }

    /// Unconditionally set the buffer state, bypassing normal transition logic.
    func setState(_ state: State) {
        mode = state
    }

    /// Remove the front entry unconditionally, ignoring `mode`.
    /// Returns `true` if an entry was removed.
    @discardableResult
    func discardFront() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeFirst()
        return true
    }

    var state: State { mode }

    var count: Int { entries.count }

    var targetBuffering: UInt64 { targetBufferingUs }

    /// Estimated live-edge PTS from the maximum sender timestamp to local wall-clock offset.
    func estimatedLivePTS() -> Int64? {
        guard let maxOffset else { return nil }
        let result = wallClock.now(in: .us).addingReportingOverflow(maxOffset)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    /// Current desired playback PTS (`estimatedLivePTS - targetBuffering`).
    ///
    /// Returns `nil` when the result would be negative — callers (e.g. the video clock
    /// anchor in `VideoRenderer.startClockIfReady`) must fall back to the front-frame PTS
    /// instead of anchoring at 0, otherwise small-PTS streams would never display.
    func targetPlaybackPTS() -> UInt64? {
        guard let estimatedLivePTS = estimatedLivePTS() else { return nil }
        let bufferingSigned = Int64(clamping: targetBufferingUs)
        let result = estimatedLivePTS.subtractingReportingOverflow(bufferingSigned)
        guard !result.overflow, result.partialValue >= 0 else { return nil }
        return UInt64(result.partialValue)
    }

    /// PTS spacing between the first two buffered samples, when available.
    var frontFrameIntervalUs: UInt64? {
        guard entries.count >= 2 else { return nil }
        return entries[1].timestampUs > entries[0].timestampUs
            ? entries[1].timestampUs - entries[0].timestampUs
            : nil
    }

    /// Current buffered depth in milliseconds (newest − oldest entry timestamp).
    var depthMs: Double {
        guard entries.count >= 2 else { return 0 }
        return Double(entries.last!.timestampUs - entries.first!.timestampUs) / 1000.0
    }

    private func updateBufferingStateIfReady() -> Bool {
        guard mode == .buffering, entries.count >= 2 else { return false }
        let oldest = entries.first!.timestampUs
        let newest = entries.last!.timestampUs
        guard newest >= oldest, newest - oldest >= targetBufferingUs else { return false }
        mode = .playing
        return true
    }

    private static func signedTimestamp(_ timestamp: UInt64) -> Int64? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        return Int64(timestamp)
    }
}
