import Foundation
import Moq
import os

extension DVR {
    /// One real group boundary read from a media timeline.
    public struct TimelinePoint: Sendable, Equatable {
        public let group: UInt64
        public let timestampUs: UInt64

        public init(group: UInt64, timestampUs: UInt64) {
            self.group = group
            self.timestampUs = timestampUs
        }
    }

    /// A track and the timeline boundaries retained for a DVR presentation.
    public struct TrackSelection: Sendable, Equatable {
        public let name: String
        public let timeline: [TimelinePoint]

        public init(name: String, timeline: [TimelinePoint]) {
            self.name = name
            self.timeline = timeline
        }
    }

    /// Audio and video timeline snapshots selected for a finite DVR presentation.
    ///
    /// Video entries are segment boundaries. The final video entry is an end sentinel and its group
    /// is not part of the presentation. Audio entries cover the same time interval and may be sparse
    /// when the publisher throttles short audio-group timeline records.
    public struct Selection: Sendable, Equatable {
        public let video: TrackSelection
        public let audio: TrackSelection

        public init(video: TrackSelection, audio: TrackSelection) {
            self.video = video
            self.audio = audio
        }
    }

    /// Keeps audio and video timeline indexes warm and resolves recent DVR windows.
    ///
    /// Start the resolver while live playback is active. Calling ``selection(for:)`` then maps a
    /// duration such as 15 seconds onto exact, already-advertised group boundaries for both tracks.
    public actor TimelineResolver {
        private enum Source {
            case live(
                broadcast: Moq.BroadcastConsumer,
                videoTimeline: Moq.Timeline,
                audioTimeline: Moq.Timeline
            )
            case snapshot
        }

        private let source: Source
        private let videoName: String
        private let audioName: String
        private let retainedEntryCount: Int

        private var videoEntries: [DVR.TimelineEntry] = []
        private var audioEntries: [DVR.TimelineEntry] = []
        private var videoConsumer: Moq.TimelineConsumer?
        private var audioConsumer: Moq.TimelineConsumer?
        private var videoTask: Task<Void, Never>?
        private var audioTask: Task<Void, Never>?
        private var timelineError: String?

        /// Creates a resolver for catalog-advertised timeline tracks.
        ///
        /// - Throws: ``SessionError/invalidConfiguration(_:)`` when either selected media track or
        ///   its timeline metadata is absent.
        public init(
            catalog: Catalog,
            videoTrackName: String,
            audioTrackName: String,
            retainedEntryCount: Int = 4_096
        ) throws {
            guard let video = catalog.videoTracks.first(where: { $0.name == videoTrackName }) else {
                throw SessionError.invalidConfiguration(
                    "Video track '\(videoTrackName)' is not in the catalog")
            }
            guard let audio = catalog.audioTracks.first(where: { $0.name == audioTrackName }) else {
                throw SessionError.invalidConfiguration(
                    "Audio track '\(audioTrackName)' is not in the catalog")
            }
            guard let videoTimeline = video.rawConfig.timeline else {
                throw SessionError.invalidConfiguration(
                    "Video track '\(videoTrackName)' has no DVR timeline")
            }
            guard let audioTimeline = audio.rawConfig.timeline else {
                throw SessionError.invalidConfiguration(
                    "Audio track '\(audioTrackName)' has no DVR timeline")
            }
            self.source = .live(
                broadcast: catalog.mediaSource.consumer,
                videoTimeline: videoTimeline,
                audioTimeline: audioTimeline
            )
            self.videoName = videoTrackName
            self.audioName = audioTrackName
            self.retainedEntryCount = max(2, retainedEntryCount)
            KitLogger.dvr.debug(
                "DVR timeline configured video=\(videoTrackName, privacy: .public) videoTimeline=\(videoTimeline.track, privacy: .public) videoTimescale=\(videoTimeline.timescale) audio=\(audioTrackName, privacy: .public) audioTimeline=\(audioTimeline.track, privacy: .public) audioTimescale=\(audioTimeline.timescale) retainedEntries=\(self.retainedEntryCount)"
            )
        }

        init(
            videoTrackName: String,
            audioTrackName: String,
            videoEntries: [DVR.TimelinePoint],
            audioEntries: [DVR.TimelinePoint]
        ) {
            self.source = .snapshot
            self.videoName = videoTrackName
            self.audioName = audioTrackName
            self.retainedEntryCount = max(2, max(videoEntries.count, audioEntries.count))
            self.videoEntries = videoEntries.map(DVR.TimelineEntry.init)
            self.audioEntries = audioEntries.map(DVR.TimelineEntry.init)
        }

        /// Starts consuming both timeline indexes. Calling it more than once is a no-op.
        public func start() async throws {
            guard videoTask == nil, audioTask == nil else {
                KitLogger.dvr.debug(
                    "DVR timeline start ignored because subscriptions are already running")
                return
            }
            guard
                case .live(let broadcast, let videoTimeline, let audioTimeline) = source
            else {
                throw SessionError.invalidConfiguration(
                    "A timeline snapshot resolver cannot start subscriptions")
            }
            KitLogger.dvr.debug(
                "DVR timeline subscribing videoTimeline=\(videoTimeline.track, privacy: .public) audioTimeline=\(audioTimeline.track, privacy: .public)"
            )
            async let videoSubscription = broadcast.subscribeTimeline(videoTimeline)
            async let audioSubscription = broadcast.subscribeTimeline(audioTimeline)
            let (videoConsumer, audioConsumer) = try await (videoSubscription, audioSubscription)
            self.videoConsumer = videoConsumer
            self.audioConsumer = audioConsumer

            videoTask = Task.detached { [weak self] in
                await Self.consume(
                    videoConsumer,
                    kind: .video,
                    onEntry: { [weak self] entry in
                        await self?.record(entry, kind: .video)
                    },
                    onError: { [weak self] error in
                        await self?.record(error: error)
                    }
                )
            }
            audioTask = Task.detached { [weak self] in
                await Self.consume(
                    audioConsumer,
                    kind: .audio,
                    onEntry: { [weak self] entry in
                        await self?.record(entry, kind: .audio)
                    },
                    onError: { [weak self] error in
                        await self?.record(error: error)
                    }
                )
            }
            KitLogger.dvr.debug("DVR timeline subscriptions started")
        }

        /// Resolves the most recent indexed window of approximately `duration`.
        ///
        /// Timeline indexes may intentionally thin short audio groups. The returned range therefore
        /// starts at the last advertised boundary at or before the target time and ends at the last
        /// boundary available to both tracks. Every returned number is real—none are extrapolated.
        public func selection(for duration: Duration) throws -> DVR.Selection {
            KitLogger.dvr.debug(
                "DVR selection requested durationUs=\(duration.microsecondsUInt64Clamped) videoEntries=\(self.videoEntries.count) audioEntries=\(self.audioEntries.count)"
            )
            guard duration > .zero else {
                throw SessionError.invalidConfiguration("DVR rewind duration must be positive")
            }
            if let timelineError {
                throw SessionError.invalidConfiguration(
                    "DVR timeline subscription failed: \(timelineError)")
            }
            guard let videoEnd = videoEntries.last, let audioEnd = audioEntries.last else {
                throw SessionError.invalidConfiguration("DVR timelines have not produced entries yet")
            }

            let sharedEnd = min(videoEnd.timestampUs, audioEnd.timestampUs)
            let target = sharedEnd.saturatingSubtract(duration.microsecondsUInt64Clamped)
            guard
                let videoEnd = videoEntries.lastIndex(where: { $0.timestampUs <= sharedEnd }),
                videoEnd > 0
            else {
                throw SessionError.invalidConfiguration(
                    "DVR timelines do not cover the requested window")
            }

            let startVideo = videoEntries.lastIndex(where: { $0.timestampUs <= target }) ?? 0
            guard startVideo < videoEnd else {
                throw SessionError.invalidConfiguration(
                    "DVR selection needs at least one complete video GOP")
            }
            let videoSlice = Array(videoEntries[startVideo...videoEnd])
            let clipStart = videoSlice[0].timestampUs
            let clipEnd = videoSlice[videoSlice.count - 1].timestampUs
            guard
                let audioSlice = DVR.TimelineIndex.slice(
                    in: audioEntries, start: clipStart, end: clipEnd)
            else {
                throw SessionError.invalidConfiguration(
                    "The audio timeline does not cover the video DVR window")
            }

            KitLogger.dvr.debug(
                "DVR selection resolved targetUs=\(target) sharedEndUs=\(clipEnd) videoBoundaries=\(videoSlice.count) videoGroups=\(videoSlice.first!.group)...\(videoSlice.last!.group) audioBoundaries=\(audioSlice.count) audioGroups=\(audioSlice.first!.group)...\(audioSlice.last!.group)"
            )

            return DVR.Selection(
                video: DVR.TrackSelection(name: videoName, timeline: videoSlice.map(\.point)),
                audio: DVR.TrackSelection(name: audioName, timeline: audioSlice.map(\.point))
            )
        }

        /// Stops timeline subscriptions and releases their background tasks.
        public func stop() {
            KitLogger.dvr.debug(
                "DVR timeline stopping videoEntries=\(self.videoEntries.count) audioEntries=\(self.audioEntries.count)"
            )
            videoTask?.cancel()
            audioTask?.cancel()
            videoTask = nil
            audioTask = nil
            videoConsumer?.cancel()
            audioConsumer?.cancel()
            videoConsumer = nil
            audioConsumer = nil
        }

        deinit {
            videoTask?.cancel()
            audioTask?.cancel()
            videoConsumer?.cancel()
            audioConsumer?.cancel()
        }

        private enum MediaKind: Sendable {
            case video
            case audio

            var label: String {
                switch self {
                case .video: "video"
                case .audio: "audio"
                }
            }
        }

        private nonisolated static func consume(
            _ consumer: Moq.TimelineConsumer,
            kind: MediaKind,
            onEntry: @escaping @Sendable (DVR.TimelineEntry) async -> Void,
            onError: @escaping @Sendable (String) async -> Void
        ) async {
            KitLogger.dvr.debug("DVR timeline consumer running kind=\(kind.label, privacy: .public)")
            do {
                while !Task.isCancelled, let entry = try await consumer.next() {
                    await onEntry(
                        DVR.TimelineEntry(group: entry.group, timestampUs: entry.timestampUs)
                    )
                }
            } catch MoqError.Cancelled {
                KitLogger.dvr.debug(
                    "DVR timeline consumer cancelled kind=\(kind.label, privacy: .public)")
                return
            } catch {
                await onError(error.localizedDescription)
                KitLogger.dvr.error(
                    "DVR timeline consumer failed kind=\(kind.label, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        private func record(_ entry: DVR.TimelineEntry, kind: MediaKind) {
            append(entry, kind: kind)
        }

        private func record(error: String) {
            timelineError = error
        }

        private func append(_ entry: DVR.TimelineEntry, kind: MediaKind) {
            switch kind {
            case .video:
                DVR.TimelineIndex.append(entry, to: &videoEntries, limit: retainedEntryCount)
            case .audio:
                DVR.TimelineIndex.append(entry, to: &audioEntries, limit: retainedEntryCount)
            }
        }
    }

    struct TimelineEntry: Sendable, Equatable {
        let group: UInt64
        let timestampUs: UInt64

        init(group: UInt64, timestampUs: UInt64) {
            self.group = group
            self.timestampUs = timestampUs
        }

        init(_ point: DVR.TimelinePoint) {
            self.init(group: point.group, timestampUs: point.timestampUs)
        }

        fileprivate var point: DVR.TimelinePoint {
            DVR.TimelinePoint(group: group, timestampUs: timestampUs)
        }
    }

    enum TimelineIndex {
        static func append(
            _ entry: DVR.TimelineEntry,
            to entries: inout [DVR.TimelineEntry],
            limit: Int
        ) {
            if let last = entries.last, entry.group <= last.group {
                if entry.group == last.group {
                    entries[entries.count - 1] = entry
                }
                return
            }
            entries.append(entry)
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }

        static func slice(
            in entries: [DVR.TimelineEntry],
            start: UInt64,
            end: UInt64
        ) -> [DVR.TimelineEntry]? {
            guard !entries.isEmpty, start < end else { return nil }
            let startIndex = entries.lastIndex(where: { $0.timestampUs <= start }) ?? 0
            guard let endIndex = entries.firstIndex(where: { $0.timestampUs >= end }),
                startIndex < endIndex
            else {
                return nil
            }
            return Array(entries[startIndex...endIndex])
        }
    }
}

extension UInt64 {
    fileprivate func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
