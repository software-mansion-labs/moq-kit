import Foundation

typealias PlaybackStatsListener = @MainActor @Sendable (PlaybackStats) -> Void

struct PlaybackStatsPublisher {
    private var statsListeners: [UUID: PlaybackStatsListener] = [:]
    private var latestStats: PlaybackStats = .empty
    private var hasPublishedStats = false

    var currentStats: PlaybackStats {
        latestStats
    }

    mutating func reset() -> [PlaybackStatsListener] {
        latestStats = .empty
        hasPublishedStats = false
        return Array(statsListeners.values)
    }

    mutating func publishStats(_ stats: PlaybackStats) -> [PlaybackStatsListener] {
        latestStats = stats
        hasPublishedStats = true
        return Array(statsListeners.values)
    }

    mutating func addListener(
        id: UUID,
        listener: @escaping PlaybackStatsListener
    ) -> PlaybackStats? {
        statsListeners[id] = listener
        return hasPublishedStats ? latestStats : nil
    }

    mutating func removeListener(id: UUID) {
        statsListeners[id] = nil
    }
}
