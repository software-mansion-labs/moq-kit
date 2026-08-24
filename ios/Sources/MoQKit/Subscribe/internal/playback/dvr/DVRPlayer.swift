import AVFoundation
import Foundation
import Moq
import os

extension DVR {
    /// A finite MoQ DVR presentation backed by the system `AVPlayer`.
    ///
    /// The player publishes an immutable local HLS index from the selected timelines. `AVPlayer`
    /// requests CMAF segments from a loopback server, which FETCHes and muxes only the corresponding
    /// MoQ groups. Video GOPs steer segment boundaries; each audio segment combines the audio groups
    /// covering the same interval.
    @MainActor
    public final class Player {
        /// The native player used for all playback and transport controls.
        public let player: AVPlayer

        /// The finite item currently installed in ``player``.
        public let item: AVPlayerItem

        private let origin: DVR.HLSOrigin
        private var stopped = false
        private var itemStatusObservation: NSKeyValueObservation?
        private var timeControlStatusObservation: NSKeyValueObservation?
        private var bufferEmptyObservation: NSKeyValueObservation?
        private var likelyToKeepUpObservation: NSKeyValueObservation?

        /// Creates a DVR player for an immutable audio and video timeline selection.
        ///
        /// The first matching catalog snapshot supplies the track containers and codec metadata.
        public convenience init(
            broadcast: Broadcast,
            selection: DVR.Selection
        ) async throws {
            KitLogger.dvr.debug(
                "DVR player waiting for catalog video=\(selection.video.name, privacy: .public) audio=\(selection.audio.name, privacy: .public)"
            )
            var iterator = broadcast.catalogs().makeAsyncIterator()
            guard let catalog = await iterator.next() else {
                throw SessionError.invalidConfiguration("The broadcast ended before DVR metadata arrived")
            }
            try await self.init(catalog: catalog, selection: selection)
        }

        /// Creates a DVR player from a catalog snapshot for the same broadcast.
        public init(
            catalog: Catalog,
            selection: DVR.Selection
        ) async throws {
            guard let videoTrack = catalog.videoTracks.first(where: { $0.name == selection.video.name }) else {
                throw SessionError.invalidConfiguration("Video track '\(selection.video.name)' is not in the catalog")
            }
            guard let audioTrack = catalog.audioTracks.first(where: { $0.name == selection.audio.name }) else {
                throw SessionError.invalidConfiguration("Audio track '\(selection.audio.name)' is not in the catalog")
            }
            let plan = try DVR.HLSPlan(selection: selection)
            guard let firstSegment = plan.segments.first, let lastSegment = plan.segments.last else {
                throw SessionError.invalidConfiguration("DVR selection contains no complete video GOP")
            }

            KitLogger.dvr.debug(
                "DVR player creating path=\(catalog.path, privacy: .public) segments=\(plan.segments.count) durationUs=\(plan.durationUs) video=\(selection.video.name, privacy: .public) videoGroups=\(firstSegment.videoGroup)...\(lastSegment.videoGroup) videoCodec=\(videoTrack.rawConfig.codec, privacy: .public) videoDescriptionBytes=\(videoTrack.rawConfig.description?.count ?? 0) audio=\(selection.audio.name, privacy: .public) audioGroups=\(firstSegment.audioGroups.lowerBound)...\(lastSegment.audioGroups.upperBound) audioCodec=\(audioTrack.rawConfig.codec, privacy: .public) audioDescriptionBytes=\(audioTrack.rawConfig.description?.count ?? 0)"
            )

            let coordinator = try DVR.SegmentCoordinator(
                plan: plan,
                video: DVR.FetchTrack(name: selection.video.name, config: videoTrack.rawConfig),
                audio: DVR.FetchTrack(name: selection.audio.name, config: audioTrack.rawConfig),
                fetcher: DVR.MediaGroupFetcher(broadcast: catalog.mediaSource.consumer)
            )
            let origin = try await DVR.HLSOrigin.start(
                coordinator: coordinator,
                videoCodec: videoTrack.rawConfig.codec,
                audioCodec: audioTrack.rawConfig.codec,
                bandwidth: Self.combinedBandwidth(
                    video: videoTrack.rawConfig.bitrate, audio: audioTrack.rawConfig.bitrate)
            )
            let asset = AVURLAsset(
                url: origin.multivariantPlaylistURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )

            let item = AVPlayerItem(asset: asset)
            self.origin = origin
            self.item = item
            self.player = AVPlayer(playerItem: item)
            startDiagnostics()
            KitLogger.dvr.debug("DVR player initialized with local HLS presentation")
        }

        /// Cancels outstanding FETCH requests and releases the current player item.
        ///
        /// A stopped DVR player cannot be restarted. Create a new instance for another range.
        public func stop() {
            guard !stopped else {
                KitLogger.dvr.debug("DVR player stop ignored because it is already stopped")
                return
            }
            KitLogger.dvr.debug(
                "DVR player stopping itemStatus=\(self.item.status.dvrDescription, privacy: .public) timeControlStatus=\(self.player.timeControlStatus.dvrDescription, privacy: .public) currentTime=\(self.player.currentTime().seconds)"
            )
            stopped = true
            player.pause()
            player.replaceCurrentItem(with: nil)
            origin.stop()
        }

        isolated deinit {
            KitLogger.dvr.debug("DVR player deinitialized")
            origin.stop()
        }

        private func startDiagnostics() {
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                KitLogger.dvr.debug(
                    "DVR player item status=\(item.status.dvrDescription, privacy: .public) duration=\(item.duration.seconds) error=\(item.error?.localizedDescription ?? "none", privacy: .public)"
                )
            }
            timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                KitLogger.dvr.debug(
                    "DVR player time control status=\(player.timeControlStatus.dvrDescription, privacy: .public) waitingReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none", privacy: .public) rate=\(player.rate) currentTime=\(player.currentTime().seconds)"
                )
            }
            bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { item, _ in
                KitLogger.dvr.debug(
                    "DVR player buffer empty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) loadedRanges=\(item.loadedTimeRanges.count)"
                )
            }
            likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { item, _ in
                KitLogger.dvr.debug(
                    "DVR player likely to keep up=\(item.isPlaybackLikelyToKeepUp) bufferEmpty=\(item.isPlaybackBufferEmpty) loadedRanges=\(item.loadedTimeRanges.count)"
                )
            }
        }

        private static func combinedBandwidth(video: UInt64?, audio: UInt64?) -> UInt64? {
            guard video != nil || audio != nil else { return nil }
            let (sum, overflow) = (video ?? 0).addingReportingOverflow(audio ?? 0)
            return overflow ? UInt64.max : sum
        }
    }
}

extension AVPlayerItem.Status {
    fileprivate var dvrDescription: String {
        switch self {
        case .unknown: "unknown"
        case .readyToPlay: "readyToPlay"
        case .failed: "failed"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

extension AVPlayer.TimeControlStatus {
    fileprivate var dvrDescription: String {
        switch self {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waitingToPlayAtSpecifiedRate"
        case .playing: "playing"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
