import AVFoundation
import CoreMedia
import MoqFFI

// MARK: - PlaybackStats

/// A snapshot of playback quality metrics, sampled over the most recent one-second window.
///
/// Obtain the current snapshot via ``Player/stats``.
public struct PlaybackStats: Sendable {
    /// Estimated end-to-end audio latency (wall-clock delay from sender to speaker).
    /// `nil` when no audio track is active.
    public let audioLatency: Duration?
    /// Estimated end-to-end video latency.
    /// `nil` when no video track is active.
    public let videoLatency: Duration?

    /// Audio stall statistics since playback started. `nil` when no audio track is active.
    public let audioStalls: StallStats?
    /// Video stall statistics since playback started. `nil` when no video track is active.
    public let videoStalls: StallStats?

    /// Audio bitrate of the incoming stream in kilobits per second. `nil` when no audio track is active.
    public let audioBitrateKbps: Double?
    /// Video bitrate of the incoming stream in kilobits per second. `nil` when no video track is active.
    public let videoBitrateKbps: Double?

    /// Startup timing milestones from ``Player/play()`` to the first accepted/playing
    /// audio and video frames.
    public let timeToFirst: TimeToFirstPlaybackStats

    /// Current video frame rate in frames per second. `nil` when no video track is active.
    public let videoFps: Double?

    /// Total audio frames dropped since playback started. `nil` when no audio track is active.
    public let audioFramesDropped: UInt64?
    /// Total video frames dropped since playback started. `nil` when no video track is active.
    public let videoFramesDropped: UInt64?

    /// Current audio ring buffer fill level. Reflects how much audio is
    /// buffered ahead of the playhead. `nil` when no audio track is active.
    public let audioRingBuffer: Duration?
    /// Current video jitter buffer fill level. `nil` when no video track is active.
    public let videoJitterBuffer: Duration?
    /// Audio frame arrival diagnostics. `nil` before audio frames arrive.
    public let audioArrival: FrameArrivalStats?
    /// Video frame arrival diagnostics. `nil` before video frames arrive.
    public let videoArrival: FrameArrivalStats?

    /// Audio track switch diagnostics. `nil` until an audio switch is requested.
    public let audioSwitches: TrackSwitchStats?
    /// Video track switch diagnostics. `nil` until a video switch is requested.
    public let videoSwitches: TrackSwitchStats?
}

extension PlaybackStats {
    static let empty = PlaybackStats(
        audioLatency: nil,
        videoLatency: nil,
        audioStalls: nil,
        videoStalls: nil,
        audioBitrateKbps: nil,
        videoBitrateKbps: nil,
        timeToFirst: .empty,
        videoFps: nil,
        audioFramesDropped: nil,
        videoFramesDropped: nil,
        audioRingBuffer: nil,
        videoJitterBuffer: nil,
        audioArrival: nil,
        videoArrival: nil,
        audioSwitches: nil,
        videoSwitches: nil
    )
}

/// Startup timing milestones from ``Player/play()``.
public struct TimeToFirstPlaybackStats: Sendable {
    /// Time to the first decoded audio frame accepted for playback.
    public let audioFrame: Duration?
    /// Time to the first video frame accepted for playback.
    public let videoFrame: Duration?
    /// Time until the first audio sample reaches the audio render callback.
    public let audioPlaying: Duration?
    /// Time until the first video frame is reported as playing.
    public let videoPlaying: Duration?
}

extension TimeToFirstPlaybackStats {
    static let empty = TimeToFirstPlaybackStats(
        audioFrame: nil,
        videoFrame: nil,
        audioPlaying: nil,
        videoPlaying: nil
    )
}

/// Stall statistics for a single track since playback started.
public struct StallStats: Sendable {
    /// Number of stall events (playback interruptions) since playback started.
    public let count: UInt64
    /// Total cumulative duration of all stall events.
    public let totalDuration: Duration
    /// Fraction of playback time spent stalling: `totalDuration / totalPlaybackDuration`.
    public let rebufferingRatio: Double
}

/// Arrival timing diagnostics for one received media stream.
public struct FrameArrivalStats: Sendable {
    /// Received compressed frames per second over the recent rolling window.
    public let receivedFramesPerSecond: Double?
    /// Average wall-clock interval between received frames over the recent rolling window.
    public let averageInterarrival: Duration?
    /// Maximum wall-clock interval between received frames over the recent rolling window.
    public let maxInterarrival: Duration?
    /// Number of intervals where wall-clock arrival was much slower than PTS spacing.
    public let slowArrivalCount: UInt64
    /// Number of intervals where wall-clock arrival was much faster than PTS spacing.
    public let fastArrivalCount: UInt64
    /// Number of frames whose timestamp was lower than the highest timestamp previously seen.
    public let outOfOrderCount: UInt64
    /// Largest timestamp regression observed for an out-of-order frame.
    public let maxOutOfOrderDelta: Duration?
    /// Number of player-detected timestamp discontinuities.
    public let discontinuityCount: UInt64
    /// Largest player-detected timestamp discontinuity.
    public let maxDiscontinuityGap: Duration?
}

/// Track switch diagnostics for one media kind.
public struct TrackSwitchStats: Sendable {
    /// Number of switch attempts requested since the current playback session started.
    public let requestedCount: UInt64
    /// Number of switch attempts that became active since the current playback session started.
    public let completedCount: UInt64
    /// Latest switch attempt, including in-progress and failed attempts.
    public let latest: TrackSwitch?
}

/// Milestones for a single track switch attempt.
public struct TrackSwitch: Sendable {
    /// Track name requested by the latest switch attempt.
    public let trackName: String?
    /// Whether this switch has emitted ``PlayerEventName/trackSwitch``.
    public let isCompleted: Bool
    /// Error message from ``PlayerEventName/trackSubscribeError``, if the switch failed.
    public let errorMessage: String?
    /// Time from switch request to the first accepted or decoded frame.
    public let switchToReady: Duration?
    /// Time from the first accepted or decoded frame to playback.
    public let readyToPlaying: Duration?
    /// Time from switch request to playback.
    public let switchToPlaying: Duration?
    /// Time from switch request to the switched rendition becoming active.
    public let switchToActive: Duration?
}

// MARK: - Player

/// Adaptive real-time player for MoQ media streams.
///
/// `Player` subscribes to one or two tracks from a ``Catalog`` (one video and/or one
/// audio track), decodes the incoming frames, and renders them in sync:
///
/// - Video frames are rendered into ``videoLayer`` — an `AVSampleBufferDisplayLayer` you can
///   embed in any `UIView` or `CALayer` hierarchy.
/// - Audio frames are decoded to PCM and played through `AVAudioEngine` using the system's
///   default audio output. No additional audio session configuration is required.
///
/// ```swift
/// let videoTrack = catalog.playableVideoTracks.first?.name
/// let audioTrack = catalog.playableAudioTracks.first?.name
///
/// let player = try Player(
///     catalog: catalog,
///     videoTrackName: videoTrack,
///     audioTrackName: audioTrack
/// )
/// view.layer.addSublayer(player.videoLayer)
/// try await player.play()
/// ```
///
/// The class is `@MainActor` — all calls must be made from the main actor.
@MainActor
public final class Player {
    /// The `AVSampleBufferDisplayLayer` that receives decoded video frames.
    ///
    /// Add this layer to your view hierarchy before calling ``play()``.
    public let videoLayer: AVSampleBufferDisplayLayer
    private let catalog: Catalog
    private var selectedVideoTrack: VideoTrackInfo?
    private var selectedAudioTrack: AudioTrackInfo?
    private var targetBuffering: Duration
    private var storedAudioVolume: Float
    private let events: PlayerEventHub
    private let tracker: PlaybackStatsTracker

    private var playbackPipeline: PlaybackPipeline?
    private var statsSamplingTask: Task<Void, Never>?
    private var isPaused = false

    private var hasVideoTrack: Bool { selectedVideoTrack != nil }

    private var hasAudioTrack: Bool { selectedAudioTrack != nil }

    /// Creates a player for the given catalog and selected track names.
    ///
    /// - Parameters:
    ///   - catalog: The catalog to play.
    ///   - videoTrackName: The selected video track name, or `nil` to disable video.
    ///   - audioTrackName: The selected audio track name, or `nil` to disable audio.
    ///   - targetBuffering: Target playback delay. Higher values improve
    ///     resilience to network jitter at the cost of increased end-to-end latency. Defaults
    ///     to 100 ms. Can be adjusted live via ``updateTargetLatency(_:)``.
    ///   - volume: Initial per-player audio output volume, clamped to `0...1`.
    /// - Throws: ``SessionError/noTracksSelected`` if both media types are disabled.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if a requested track name does
    ///   not exist in the catalog.
    public init(
        catalog: Catalog,
        videoTrackName: String? = nil,
        audioTrackName: String? = nil,
        targetBuffering: Duration = .milliseconds(100),
        volume: Float = 1.0
    ) throws {
        let selection = try Self.resolveSelection(
            in: catalog,
            videoTrackName: videoTrackName,
            audioTrackName: audioTrackName
        )

        self.catalog = catalog
        self.selectedVideoTrack = selection.videoTrack
        self.selectedAudioTrack = selection.audioTrack
        self.targetBuffering = targetBuffering
        self.storedAudioVolume = Self.clampedVolume(volume)
        self.videoLayer = AVSampleBufferDisplayLayer()
        let events = PlayerEventHub()
        self.events = events
        self.tracker = PlaybackStatsTracker(events: events)

        events.emit(.playerInit(sessionEvent))
        emitSelectedTrackSelect()
    }

    // MARK: - Public API

    /// Per-player audio output volume, clamped to `0...1`.
    public var audioVolume: Float {
        get { storedAudioVolume }
        set { setVolume(newValue) }
    }

    /// Sets the per-player audio output volume without affecting other audio on the system.
    ///
    /// You can call this before playback starts or while playback is already running.
    public func setVolume(_ volume: Float) {
        let clamped = Self.clampedVolume(volume)
        storedAudioVolume = clamped
        playbackPipeline?.setVolume(clamped)
    }

    /// Adjusts the target playback delay without interrupting playback.
    ///
    /// The change takes effect immediately on both the audio ring buffer and the video jitter
    /// buffer. Lowering the value reduces latency but increases the risk of stalls on lossy
    /// networks; raising it improves resilience.
    ///
    /// - Parameter latency: New target buffering depth.
    public func updateTargetLatency(_ latency: Duration) {
        targetBuffering = latency
        playbackPipeline?.updateTargetLatency(latency)
    }

    /// A snapshot of current playback quality metrics.
    ///
    /// Follows ``Player`` main-actor isolation.
    /// Values are sampled over the most recent one-second window. See ``PlaybackStats``
    /// for field-level documentation.
    public var stats: PlaybackStats {
        tracker.currentStats()
    }

    /// Subscribes to player lifecycle events.
    ///
    /// Events represent transitions: subscribe lifecycle, frame-ready, playing,
    /// quality changes, stalls, rebuffer, errors. Subscribe before calling ``play()``
    /// when startup events are needed — events emitted before subscription are not
    /// replayed. Periodic samples (bitrate, latency, buffer fill, fps) are not events;
    /// use ``subscribeStats(_:)`` for those. The returned subscription must be retained
    /// for as long as events are needed.
    public func subscribeEvents(
        _ listener: @escaping @MainActor @Sendable (PlayerEvent) -> Void
    ) -> PlayerEventSubscription {
        events.subscribe(listener)
    }

    /// Subscribes to pushed ``PlaybackStats`` snapshots.
    ///
    /// The listener is invoked on the main actor when the next sample is published.
    /// Naive consumers cannot distinguish an "empty" initial snapshot from real data,
    /// so the first push is deferred until a real sample is available.
    public func subscribeStats(
        _ listener: @escaping @MainActor @Sendable (PlaybackStats) -> Void
    ) -> PlayerEventSubscription {
        tracker.subscribeStats(listener)
    }

    /// Subscribes to the selected tracks and begins decoding and rendering.
    ///
    /// Call ``pause()`` to temporarily suspend rendering without releasing the track
    /// subscriptions, or
    /// ``Player/stopAll(reason:)`` to fully tear down.
    /// Calling `play()` while the player is already running is a no-op.
    ///
    /// - Throws: ``SessionError`` if a track subscription or renderer initialisation fails.
    public func play() async throws {
        guard playbackPipeline == nil else {
            KitLogger.player.debug("Ignoring play() because playback pipeline is already active for \(self.playbackLogDescription)")
            return
        }

        try validateSelectedTracks()

        KitLogger.player.debug("Starting real-time player for \(self.playbackLogDescription), targetBuffering=\(self.targetBuffering.milliseconds)ms")
        events.emit(.playbackRequest(sessionEvent))
        tracker.beginSession(
            rebufferKind: selectedAudioTrack != nil ? .audio : .video
        )
        let shouldEmitResume = isPaused
        playbackPipeline = try makePlaybackPipeline()
        if shouldEmitResume {
            events.emit(.playbackResume(sessionEvent))
        }
        isPaused = false
        startStatsSampling()
        publishStatsSample()
    }

    /// Pauses playback and cancels all track subscriptions.
    ///
    /// Emits ``PlayerEventName/playbackPause``. To resume, call ``play()`` again —
    /// it will re-subscribe to the tracks and restart rendering from the current live
    /// position.
    public func pause() async {
        KitLogger.player.debug("Pausing real-time player for \(self.playbackLogDescription)")
        teardown(permanent: false, reason: "pause()")
        events.emit(.playbackPause(sessionEvent))
        isPaused = true
    }

    /// Stops playback, closes all track subscriptions, and releases all rendering resources.
    ///
    /// The player cannot be reused after this call — create a new ``Player`` instance to
    /// start playback again.
    public func stopAll(reason: String = "caller requested stopAll") async {
        KitLogger.player.debug("Stopping real-time player for \(self.playbackLogDescription), reason=\(reason)")
        teardown(permanent: true, reason: reason)
    }

    /// Switches to a different video rendition with minimal interruption.
    ///
    /// When both the current and new selections are active video tracks, MoQKit keeps the
    /// old track alive until the new one starts rendering. Switching video on from `nil`,
    /// or turning it off, may require a full playback restart and cause a brief gap.
    ///
    /// Emits ``PlayerEventName/trackSelect`` when the selected track is committed,
    /// and ``PlayerEventName/trackSwitch`` when an active rendition switch starts
    /// rendering.
    ///
    /// - Parameter trackName: A video track name from the current catalog, or `nil`
    ///   to disable video playback.
    /// - Throws: ``SessionError`` if subscribing to the new track fails.
    public func switchTrack(to trackName: String?) async throws {
        let newTrack = try Self.resolveVideoTrack(named: trackName, in: catalog)
        guard newTrack?.name != selectedVideoTrack?.name else { return }
        guard newTrack != nil || selectedAudioTrack != nil else {
            throw SessionError.noTracksSelected
        }
        try validatePlayable(newTrack)

        let wasVideoEnabled = selectedVideoTrack != nil

        guard let playbackPipeline else {
            selectedVideoTrack = newTrack
            emitTrackSelect(kind: .video, trackName: newTrack?.name)
            return
        }

        if wasVideoEnabled, let newTrack {
            switch try playbackPipeline.switchVideo(to: newTrack) {
            case .handled:
                selectedVideoTrack = newTrack
                emitTrackSelect(kind: .video, trackName: newTrack.name)
                return
            case .restartRequired:
                break
            }
        }

        selectedVideoTrack = newTrack
        emitTrackSelect(kind: .video, trackName: newTrack?.name)
        try await restartPlaybackForSelectionChange()
    }

    /// Switches to a different audio rendition with minimal interruption.
    ///
    /// When both the current and new selections are active audio tracks, MoQKit changes
    /// over in place. Switching audio on from `nil`, or turning it off, may require a full
    /// playback restart and cause a brief gap.
    ///
    /// Emits ``PlayerEventName/trackSelect`` when the selected track is committed,
    /// and ``PlayerEventName/trackSwitch`` when an active rendition switch starts
    /// rendering.
    ///
    /// - Parameter trackName: An audio track name from the current catalog, or `nil`
    ///   to disable audio playback.
    /// - Throws: ``SessionError`` if subscribing to the new track fails.
    public func switchAudioTrack(to trackName: String?) async throws {
        let newTrack = try Self.resolveAudioTrack(named: trackName, in: catalog)
        guard newTrack?.name != selectedAudioTrack?.name else { return }
        guard selectedVideoTrack != nil || newTrack != nil else {
            throw SessionError.noTracksSelected
        }
        try validatePlayable(newTrack)

        let wasAudioEnabled = selectedAudioTrack != nil

        guard let playbackPipeline else {
            selectedAudioTrack = newTrack
            emitTrackSelect(kind: .audio, trackName: newTrack?.name)
            return
        }

        if wasAudioEnabled, let newTrack {
            switch try playbackPipeline.switchAudio(to: newTrack) {
            case .handled:
                selectedAudioTrack = newTrack
                emitTrackSelect(kind: .audio, trackName: newTrack.name)
                return
            case .restartRequired:
                break
            }
        }

        selectedAudioTrack = newTrack
        emitTrackSelect(kind: .audio, trackName: newTrack?.name)
        try await restartPlaybackForSelectionChange()
    }

    deinit {
        KitLogger.player.debug("Player deinit; stopping any active playback pipeline")
        statsSamplingTask?.cancel()
        playbackPipeline?.stop(reason: "Player deinit")
        events.emit(.playerDestroy)
    }

    // MARK: - Private: teardown

    private func teardown(permanent: Bool, reason: String) {
        if let playbackPipeline {
            tracker.publishStats(playbackPipeline.getStats())
        } else {
            KitLogger.player.debug("Player teardown requested with no active pipeline for \(self.playbackLogDescription), permanent=\(permanent), reason=\(reason)")
        }
        stopStatsSampling()
        playbackPipeline?.stop(reason: "Player teardown permanent=\(permanent), reason=\(reason)")
        playbackPipeline = nil
        tracker.closeOutInFlightStalls()

        if permanent {
            tracker.emitPlaybackEnd(reason: reason)
            tracker.reset()
            isPaused = false
        }
    }

    private func restartPlaybackForSelectionChange() async throws {
        teardown(permanent: false, reason: "track selection changed")
        try await play()
    }

    // MARK: - Private: play() helpers

    private func makePlaybackPipeline() throws -> PlaybackPipeline {
        guard hasVideoTrack || hasAudioTrack else {
            throw SessionError.noTracksSelected
        }
        return try PlaybackPipeline(
            catalog: catalog,
            videoTrack: selectedVideoTrack,
            audioTrack: selectedAudioTrack,
            targetBuffering: targetBuffering,
            volume: storedAudioVolume,
            videoLayer: videoLayer,
            tracker: tracker
        )
    }

    private func startStatsSampling() {
        statsSamplingTask?.cancel()
        statsSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.publishStatsSample()
            }
        }
    }

    private func stopStatsSampling() {
        statsSamplingTask?.cancel()
        statsSamplingTask = nil
    }

    private func publishStatsSample() {
        guard let playbackPipeline else { return }
        tracker.publishStats(playbackPipeline.getStats())
    }

    // MARK: - Private: helpers

    private nonisolated static func clampedVolume(_ volume: Float) -> Float {
        guard !volume.isNaN else { return 0 }
        return min(max(volume, 0), 1)
    }

    private var playbackLogDescription: String {
        "catalog=\(catalog.path), video=\(selectedVideoTrack?.name ?? "none"), audio=\(selectedAudioTrack?.name ?? "none")"
    }

    private var sessionEvent: PlayerSessionEvent {
        PlayerSessionEvent(
            catalogPath: catalog.path,
            targetBuffering: targetBuffering,
            videoTrackName: selectedVideoTrack?.name,
            audioTrackName: selectedAudioTrack?.name
        )
    }

    private func emitSelectedTrackSelect() {
        if let selectedVideoTrack {
            emitTrackSelect(kind: .video, trackName: selectedVideoTrack.name)
        }
        if let selectedAudioTrack {
            emitTrackSelect(kind: .audio, trackName: selectedAudioTrack.name)
        }
    }

    private func emitTrackSelect(kind: PlayerTrackKind, trackName: String?) {
        events.emit(
            .trackSelect(
                PlayerTrackSelectionEvent(
                    kind: kind,
                    trackName: trackName
                )
            )
        )
    }

    private func validateSelectedTracks() throws {
        try validatePlayable(selectedVideoTrack)
        try validatePlayable(selectedAudioTrack)
    }

    private func validatePlayable(_ track: VideoTrackInfo?) throws {
        guard let track, let reason = track.unsupportedReason else { return }
        throw SessionError.unsupportedCodec(
            "Video track '\(track.name)' is not playable: \(reason)")
    }

    private func validatePlayable(_ track: AudioTrackInfo?) throws {
        guard let track, let reason = track.unsupportedReason else { return }
        throw SessionError.unsupportedCodec(
            "Audio track '\(track.name)' is not playable: \(reason)")
    }

    private static func resolveSelection(
        in catalog: Catalog,
        videoTrackName: String?,
        audioTrackName: String?
    ) throws -> (videoTrack: VideoTrackInfo?, audioTrack: AudioTrackInfo?) {
        let videoTrack = try resolveVideoTrack(named: videoTrackName, in: catalog)
        let audioTrack = try resolveAudioTrack(named: audioTrackName, in: catalog)

        guard videoTrack != nil || audioTrack != nil else {
            throw SessionError.noTracksSelected
        }

        return (videoTrack, audioTrack)
    }

    private static func resolveVideoTrack(
        named trackName: String?,
        in catalog: Catalog
    ) throws -> VideoTrackInfo? {
        guard let trackName else { return nil }
        guard let track = catalog.videoTracks.first(where: { $0.name == trackName }) else {
            throw SessionError.invalidConfiguration(
                "Unknown video track '\(trackName)' for catalog \(catalog.path)"
            )
        }
        return track
    }

    private static func resolveAudioTrack(
        named trackName: String?,
        in catalog: Catalog
    ) throws -> AudioTrackInfo? {
        guard let trackName else { return nil }
        guard let track = catalog.audioTracks.first(where: { $0.name == trackName }) else {
            throw SessionError.invalidConfiguration(
                "Unknown audio track '\(trackName)' for catalog \(catalog.path)"
            )
        }
        return track
    }
}
