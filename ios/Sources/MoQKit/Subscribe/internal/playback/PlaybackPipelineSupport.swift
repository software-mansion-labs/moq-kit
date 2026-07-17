import Foundation

struct PlaybackSubscriptions {
    var video: MediaTrack?
    var audio: MediaTrack?
}

/// Holds the previous video rendition alive until the renderer activates or aborts
/// the pending rendition.
final class TrackIngestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var subscription: MediaTrack?

    init(task: Task<Void, Never>?, subscription: MediaTrack?) {
        self.task = task
        self.subscription = subscription
    }

    func close() {
        lock.lock()
        let task = self.task
        let subscription = self.subscription
        self.task = nil
        self.subscription = nil
        lock.unlock()

        task?.cancel()
        subscription?.close()
    }

    func take() -> (task: Task<Void, Never>?, subscription: MediaTrack?) {
        lock.lock()
        defer { lock.unlock() }
        let resources = (task, subscription)
        task = nil
        subscription = nil
        return resources
    }
}

extension PlaybackPipeline {
    static func makePlaybackSubscriptions(
        videoTrack: VideoTrackInfo?,
        videoEpoch: TrackEpoch,
        audioTrack: AudioTrackInfo?,
        audioEpoch: TrackEpoch,
        mediaSource: BroadcastMediaSource,
        maxLatency: Duration,
        tracker: PlaybackStatsTracker
    ) throws -> PlaybackSubscriptions {
        var subscriptions = PlaybackSubscriptions()
        // Capture the first error only; per-track failures are reported via
        // `.trackSubscribeError` events. Rethrow only when every requested track failed.
        var firstError: Error?

        if let videoTrack {
            tracker.emitSubscribeStart(
                kind: .video, trackName: videoTrack.name, trackEpoch: videoEpoch
            )
            KitLogger.player.debug(
                "Video track: \(videoTrack.name), codec=\(videoTrack.config.codec), config=\(videoTrack.config.debugDescription), container=\(videoTrack.rawConfig.container.moqKitDescription)"
            )
            do {
                subscriptions.video = try mediaSource.subscribeMedia(
                    MediaTrackRequest(track: videoTrack, targetBuffering: maxLatency)
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to video track \(videoTrack.name): \(error)")
                tracker.emitSubscribeError(
                    kind: .video,
                    trackName: videoTrack.name,
                    message: error.localizedDescription,
                    trackEpoch: videoEpoch
                )
            }
        }

        if let audioTrack {
            tracker.emitSubscribeStart(
                kind: .audio, trackName: audioTrack.name, trackEpoch: audioEpoch
            )
            KitLogger.player.debug(
                "Audio track: \(audioTrack.name), config = \(audioTrack.config.debugDescription), container=\(audioTrack.rawConfig.container.moqKitDescription)"
            )
            do {
                subscriptions.audio = try mediaSource.subscribeMedia(
                    MediaTrackRequest(track: audioTrack, targetBuffering: maxLatency)
                )
            } catch {
                if firstError == nil { firstError = error }
                KitLogger.player.error(
                    "Failed to subscribe to audio track \(audioTrack.name): \(error)")
                tracker.emitSubscribeError(
                    kind: .audio,
                    trackName: audioTrack.name,
                    message: error.localizedDescription,
                    trackEpoch: audioEpoch
                )
            }
        }

        if subscriptions.video == nil && subscriptions.audio == nil, let firstError {
            throw firstError
        }
        return subscriptions
    }

    static func playbackLatency(
        liveTime: Int64?, currentTimeUs: UInt64
    ) -> Duration? {
        guard let liveTime, currentTimeUs <= UInt64(Int64.max) else { return nil }
        let result = liveTime.subtractingReportingOverflow(Int64(currentTimeUs))
        guard !result.overflow else { return nil }
        return .microseconds(max(0, result.partialValue))
    }

    static func latencyUs(
        liveTime: Int64?,
        currentTimeUs: UInt64
    ) -> Int64? {
        guard let liveTime, currentTimeUs <= UInt64(Int64.max) else { return nil }
        let result = liveTime.subtractingReportingOverflow(Int64(currentTimeUs))
        guard !result.overflow else { return nil }
        return max(0, result.partialValue)
    }
}
