import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - PlaybackStats

/// A snapshot of playback quality metrics, sampled over the most recent one-second window.
///
/// Obtain the current snapshot via ``Player/stats``.
public struct PlaybackStats: Sendable {
    /// Estimated end-to-end audio latency in milliseconds (wall-clock delay from sender to speaker).
    /// `nil` when no audio track is active.
    public let audioLatencyMs: Double?
    /// Estimated end-to-end video latency in milliseconds.
    /// `nil` when no video track is active.
    public let videoLatencyMs: Double?

    /// Audio stall statistics since playback started. `nil` when no audio track is active.
    public let audioStalls: StallStats?
    /// Video stall statistics since playback started. `nil` when no video track is active.
    public let videoStalls: StallStats?

    /// Audio bitrate of the incoming stream in kilobits per second. `nil` when no audio track is active.
    public let audioBitrateKbps: Double?
    /// Video bitrate of the incoming stream in kilobits per second. `nil` when no video track is active.
    public let videoBitrateKbps: Double?

    /// Time from ``Player/play()`` to the first decoded audio frame, in milliseconds.
    /// `nil` before the first frame arrives or when no audio track is active.
    public let timeToFirstAudioFrameMs: Double?
    /// Time from ``Player/play()`` to the first decoded video frame, in milliseconds.
    /// `nil` before the first frame arrives or when no video track is active.
    public let timeToFirstVideoFrameMs: Double?

    /// Current video frame rate in frames per second. `nil` when no video track is active.
    public let videoFps: Double?

    /// Total audio frames dropped since playback started. `nil` when no audio track is active.
    public let audioFramesDropped: UInt64?
    /// Total video frames dropped since playback started. `nil` when no video track is active.
    public let videoFramesDropped: UInt64?

    /// Current audio ring buffer fill level in milliseconds. Reflects how much audio is
    /// buffered ahead of the playhead. `nil` when no audio track is active.
    public let audioRingBufferMs: Double?
    /// Current video jitter buffer fill level in milliseconds. `nil` when no video track is active.
    public let videoJitterBufferMs: Double?
    /// Audio frame arrival diagnostics. `nil` before audio frames arrive.
    public let audioArrival: FrameArrivalStats?
    /// Video frame arrival diagnostics. `nil` before video frames arrive.
    public let videoArrival: FrameArrivalStats?
}

extension PlaybackStats {
    static let empty = PlaybackStats(
        audioLatencyMs: nil,
        videoLatencyMs: nil,
        audioStalls: nil,
        videoStalls: nil,
        audioBitrateKbps: nil,
        videoBitrateKbps: nil,
        timeToFirstAudioFrameMs: nil,
        timeToFirstVideoFrameMs: nil,
        videoFps: nil,
        audioFramesDropped: nil,
        videoFramesDropped: nil,
        audioRingBufferMs: nil,
        videoJitterBufferMs: nil,
        audioArrival: nil,
        videoArrival: nil
    )
}

/// Stall statistics for a single track since playback started.
public struct StallStats: Sendable {
    /// Number of stall events (playback interruptions) since playback started.
    public let count: UInt64
    /// Total cumulative duration of all stall events in milliseconds.
    public let totalDurationMs: Double
    /// Fraction of playback time spent stalling: `totalDurationMs / totalPlaybackDurationMs`.
    public let rebufferingRatio: Double
}

/// Arrival timing diagnostics for one received media stream.
public struct FrameArrivalStats: Sendable {
    /// Received compressed frames per second over the recent rolling window.
    public let receivedFramesPerSecond: Double?
    /// Average wall-clock interval between received frames over the recent rolling window.
    public let averageInterarrivalMs: Double?
    /// Maximum wall-clock interval between received frames over the recent rolling window.
    public let maxInterarrivalMs: Double?
    /// Number of intervals where wall-clock arrival lagged PTS spacing by the gap threshold.
    public let arrivalGapCount: UInt64
    /// Number of intervals where frames arrived much faster than their PTS spacing.
    public let burstCount: UInt64
    /// Number of frames whose timestamp was lower than the highest timestamp previously seen.
    public let outOfOrderCount: UInt64
    /// Largest timestamp regression observed for an out-of-order frame.
    public let maxOutOfOrderDeltaMs: Double?
    /// Number of player-detected timestamp discontinuities.
    public let discontinuityCount: UInt64
    /// Largest player-detected timestamp discontinuity.
    public let maxDiscontinuityGapMs: Double?
}

// MARK: - PlayerEvent

/// Events emitted on ``Player/events`` during playback.
public enum PlayerEvent: Sendable {
    /// The first frame of the given track kind was successfully decoded and rendered.
    case trackPlaying(TrackKind)
    /// Playback of the given track kind was paused via ``Player/pause()``.
    case trackPaused(TrackKind)
    /// The remote sender stopped the given track (the track stream ended).
    case trackStopped(TrackKind)
    /// All active tracks have stopped. The events stream completes immediately after this event.
    case allTracksStopped
    /// A non-fatal error occurred on the given track. Playback of other tracks continues.
    case error(TrackKind, String)
    /// The first frame of a switched-in rendition was rendered. Emitted after a successful
    /// ``Player/switchTrack(to:)-7ugy3`` or ``Player/switchTrack(to:)-3kgck`` call.
    case trackSwitched(TrackKind)

    /// Identifies which type of media track an event relates to.
    public enum TrackKind: String, Sendable {
        case video, audio
    }
}

// MARK: - Player

/// Adaptive real-time player for MoQ media streams.
///
/// `Player` subscribes to one or two tracks from a ``Catalog`` (one video and/or
/// one audio track), decodes the incoming frames, and renders them in sync:
///
/// - Video frames are rendered into ``videoLayer`` — an `AVSampleBufferDisplayLayer` you can
///   embed in any `UIView` or `CALayer` hierarchy.
/// - Audio frames are decoded to PCM and played through `AVAudioEngine` using the system's
///   default audio output. No additional audio session configuration is required.
///
/// ```swift
/// let player = try Player(
///     catalog: catalog,
///     videoTrackName: catalog.videoTracks.first?.name,
///     audioTrackName: catalog.audioTracks.first?.name
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
    /// Emits ``PlayerEvent`` values as playback progresses.
    ///
    /// The stream completes after ``allTracksStopped`` is emitted or after ``stopAll()`` is called.
    public let events: AsyncStream<PlayerEvent>

    private let catalog: Catalog
    private var selectedVideoTrack: VideoTrackInfo?
    private var selectedAudioTrack: AudioTrackInfo?
    private var targetBufferingMs: UInt64
    private var storedAudioVolume: Float
    private let eventsContinuation: AsyncStream<PlayerEvent>.Continuation

    private var playbackPipeline: PlaybackPipeline?
    private var lastStats: PlaybackStats = .empty

    private var hasVideoTrack: Bool { selectedVideoTrack != nil }

    private var hasAudioTrack: Bool { selectedAudioTrack != nil }

    /// Creates a player for the given catalog and selected track names.
    ///
    /// - Parameters:
    ///   - catalog: The catalog to play.
    ///   - videoTrackName: The selected video track name, or `nil` to disable video.
    ///   - audioTrackName: The selected audio track name, or `nil` to disable audio.
    ///   - targetBufferingMs: Target playout delay in milliseconds. Higher values improve
    ///     resilience to network jitter at the cost of increased end-to-end latency. Defaults
    ///     to 100 ms. Can be adjusted live via ``updateTargetLatency(ms:)``.
    ///   - volume: Initial per-player audio output volume, clamped to `0...1`.
    /// - Throws: ``SessionError/noTracksSelected`` if both media types are disabled.
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if a requested track name does
    ///   not exist in the catalog.
    public init(
        catalog: Catalog,
        videoTrackName: String? = nil,
        audioTrackName: String? = nil,
        targetBufferingMs: UInt64 = 100,
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
        self.targetBufferingMs = targetBufferingMs
        self.storedAudioVolume = Self.clampedVolume(volume)
        self.videoLayer = AVSampleBufferDisplayLayer()

        var cont: AsyncStream<PlayerEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
    }

    // MARK: - Public API

    /// Per-player audio output volume, clamped to `0...1`.
    public var audioVolume: Float {
        get { storedAudioVolume }
        set { setVolume(newValue) }
    }

    /// Sets the per-player audio output volume without affecting other audio on the system.
    public func setVolume(_ volume: Float) {
        let clamped = Self.clampedVolume(volume)
        storedAudioVolume = clamped
        playbackPipeline?.setVolume(clamped)
    }

    /// Adjusts the target playout delay without interrupting playback.
    ///
    /// The change takes effect immediately on both the audio ring buffer and the video jitter
    /// buffer. Lowering the value reduces latency but increases the risk of stalls on lossy
    /// networks; raising it improves resilience.
    ///
    /// - Parameter ms: New target buffering depth in milliseconds.
    public func updateTargetLatency(ms: UInt64) {
        targetBufferingMs = ms
        playbackPipeline?.updateTargetLatency(ms: ms)
    }

    /// A snapshot of current playback quality metrics.
    ///
    /// Follows ``Player`` main-actor isolation.
    /// Values are sampled over the most recent one-second window. See ``PlaybackStats``
    /// for field-level documentation.
    public var stats: PlaybackStats {
        guard let playbackPipeline else { return lastStats }
        let stats = playbackPipeline.getStats()
        lastStats = stats
        return stats
    }

    /// Subscribes to the selected tracks and begins decoding and rendering.
    ///
    /// Playback events are emitted on ``events``. Call ``pause()`` to temporarily suspend
    /// rendering without releasing the track subscriptions, or ``stopAll()`` to fully tear down.
    ///
    /// - Throws: ``SessionError`` if a track subscription or renderer initialisation fails.
    public func play() async throws {
        guard playbackPipeline == nil else {
            KitLogger.player.debug("Ignoring play() because playback pipeline is already active for \(self.playbackLogDescription)")
            return
        }

        try validateSelectedTracks()

        KitLogger.player.debug("Starting real-time player for \(self.playbackLogDescription), targetBufferingMs=\(self.targetBufferingMs)")
        playbackPipeline = try makePlaybackPipeline()
    }

    /// Pauses playback and cancels all track subscriptions.
    ///
    /// Emits ``PlayerEvent/trackPaused(_:)`` for each active track. To resume, call
    /// ``play()`` again — it will re-subscribe to the tracks and restart rendering from the
    /// current live position.
    public func pause() async {
        let hadVideoTrack = hasVideoTrack
        let hadAudioTrack = hasAudioTrack
        KitLogger.player.debug("Pausing real-time player for \(self.playbackLogDescription)")
        teardown(permanent: false, reason: "pause()")

        if hadVideoTrack {
            eventsContinuation.yield(.trackPaused(.video))
        }
        if hadAudioTrack {
            eventsContinuation.yield(.trackPaused(.audio))
        }
    }

    /// Stops playback, closes all track subscriptions, and releases all rendering resources.
    ///
    /// The ``events`` stream completes after this call. The player cannot be reused — create a
    /// new ``Player`` instance to start playback again.
    public func stopAll(reason: String = "caller requested stopAll") async {
        KitLogger.player.debug("Stopping real-time player for \(self.playbackLogDescription), reason=\(reason)")
        teardown(permanent: true, reason: reason)
    }

    /// Switches to a different video rendition seamlessly.
    ///
    /// The new subscription is started in parallel with the old one. The old track keeps
    /// feeding the jitter buffer until the new rendition delivers its first frame, at which
    /// point the old ingest task is cancelled. No flush occurs — the jitter buffer provides
    /// continuity, and `AVSampleBufferDisplayLayer` handles per-frame format description
    /// changes natively.
    ///
    /// Emits ``PlayerEvent/trackSwitched(_:)`` when the first frame of the new rendition
    /// is rendered. Enabling video from `nil` or disabling the current video selection
    /// falls back to a playback restart and may cause a brief gap.
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
            return
        }

        if wasVideoEnabled, let newTrack {
            switch try playbackPipeline.switchVideo(to: newTrack) {
            case .handled:
                selectedVideoTrack = newTrack
                return
            case .restartRequired:
                break
            }
        }

        selectedVideoTrack = newTrack
        try await restartPlaybackForSelectionChange()
    }

    /// Switches to a different audio rendition seamlessly.
    ///
    /// The new ingest task is started immediately; the old one is cancelled right after.
    /// The ring buffer's timestamp-based write positioning means both decoders briefly
    /// write identical PCM to the same positions — there is no audible glitch, and no
    /// ring buffer reset is needed.
    ///
    /// Emits ``PlayerEvent/trackSwitched(_:)`` when the first frame of the new rendition
    /// is rendered. Enabling audio from `nil` or disabling the current audio selection
    /// falls back to a playback restart and may cause a brief gap.
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
            return
        }

        if wasAudioEnabled, let newTrack {
            switch try playbackPipeline.switchAudio(to: newTrack) {
            case .handled:
                selectedAudioTrack = newTrack
                return
            case .restartRequired:
                break
            }
        }

        selectedAudioTrack = newTrack
        try await restartPlaybackForSelectionChange()
    }

    deinit {
        KitLogger.player.debug("Player deinit; stopping any active playback pipeline")
        playbackPipeline?.stop(reason: "Player deinit")
        eventsContinuation.finish()
    }

    // MARK: - Private: teardown

    private func teardown(permanent: Bool, reason: String) {
        if let playbackPipeline {
            lastStats = playbackPipeline.getStats()
        } else {
            KitLogger.player.debug("Player teardown requested with no active pipeline for \(self.playbackLogDescription), permanent=\(permanent), reason=\(reason)")
        }
        playbackPipeline?.stop(reason: "Player teardown permanent=\(permanent), reason=\(reason)")
        playbackPipeline = nil

        if permanent {
            lastStats = .empty

            eventsContinuation.finish()
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
            targetBufferingMs: targetBufferingMs,
            volume: storedAudioVolume,
            videoLayer: videoLayer,
            eventContinuation: eventsContinuation
        )
    }

    // MARK: - Private: helpers

    private nonisolated static func clampedVolume(_ volume: Float) -> Float {
        guard !volume.isNaN else { return 0 }
        return min(max(volume, 0), 1)
    }

    private var playbackLogDescription: String {
        "catalog=\(catalog.path), video=\(selectedVideoTrack?.name ?? "none"), audio=\(selectedAudioTrack?.name ?? "none")"
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
