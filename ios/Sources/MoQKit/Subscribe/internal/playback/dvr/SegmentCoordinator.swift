import Foundation
import Moq
import os

extension DVR {
    final class SegmentCoordinator: @unchecked Sendable {
        private struct Key: Hashable {
            let kind: DVR.MediaKind
            let index: Int
        }

        let plan: DVR.HLSPlan
        let videoInitialization: Data
        let audioInitialization: Data

        private let video: DVR.FetchTrack
        private let audio: DVR.FetchTrack
        private let fetcher: DVR.MediaGroupFetcher
        private let videoMuxer: Moq.CMAFMuxer
        private let audioMuxer: Moq.CMAFMuxer
        private struct State {
            var tasks: [Key: Task<Data, Error>] = [:]
            var stopped = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(
            plan: DVR.HLSPlan,
            video: DVR.FetchTrack,
            audio: DVR.FetchTrack,
            fetcher: DVR.MediaGroupFetcher
        ) throws {
            guard case .video(let videoConfig) = video.configuration,
                case .audio(let audioConfig) = audio.configuration
            else {
                throw DVR.PlaybackError.invalidTrackConfiguration
            }
            let videoMuxer = try Moq.CMAFMuxer(
                video: videoConfig,
                originTimestampUs: plan.originTimestampUs
            )
            let audioMuxer = try Moq.CMAFMuxer(
                audio: audioConfig,
                originTimestampUs: plan.originTimestampUs
            )
            self.plan = plan
            self.video = video
            self.audio = audio
            self.fetcher = fetcher
            self.videoMuxer = videoMuxer
            self.audioMuxer = audioMuxer
            self.videoInitialization = videoMuxer.initialization
            self.audioInitialization = audioMuxer.initialization
        }

        func segment(kind: DVR.MediaKind, index: Int) async throws -> Data {
            guard plan.segments.indices.contains(index) else {
                throw DVR.PlaybackError.segmentUnavailable(kind, index)
            }
            let key = Key(kind: kind, index: index)
            let segment = plan.segments[index]
            let task = try task(for: key, segment: segment)

            do {
                return try await task.value
            } catch {
                state.withLock { $0.tasks[key] = nil }
                throw error
            }
        }

        private func task(
            for key: Key,
            segment: DVR.Segment
        ) throws -> Task<Data, Error> {
            let video = video
            let audio = audio
            let fetcher = fetcher
            let videoMuxer = videoMuxer
            let audioMuxer = audioMuxer
            return try state.withLock { state -> Task<Data, Error> in
                guard !state.stopped else { throw CancellationError() }
                if let task = state.tasks[key] {
                    return task
                }
                let task = Task.detached(priority: .userInitiated) {
                    let started = ContinuousClock.now
                    switch key.kind {
                    case .video:
                        return try await Self.videoSegment(
                            index: key.index,
                            segment: segment,
                            track: video,
                            fetcher: fetcher,
                            muxer: videoMuxer,
                            started: started
                        )
                    case .audio:
                        return try await Self.audioSegment(
                            index: key.index,
                            segment: segment,
                            track: audio,
                            fetcher: fetcher,
                            muxer: audioMuxer,
                            started: started
                        )
                    }
                }
                state.tasks[key] = task
                return task
            }
        }

        private static func videoSegment(
            index: Int,
            segment: DVR.Segment,
            track: DVR.FetchTrack,
            fetcher: DVR.MediaGroupFetcher,
            muxer: Moq.CMAFMuxer,
            started: ContinuousClock.Instant
        ) async throws -> Data {
            let frames = try await fetcher.fetch(
                track.name,
                segment.videoGroup,
                track.container
            )
            guard !frames.isEmpty else {
                throw DVR.PlaybackError.segmentUnavailable(.video, index)
            }
            let data = try muxer.fragment(
                sequence: UInt32(clamping: index + 1),
                frames: frames
            )
            KitLogger.dvr.debug(
                "DVR HLS video segment ready index=\(index) group=\(segment.videoGroup) frames=\(frames.count) bytes=\(data.count) elapsedMs=\(started.duration(to: .now).milliseconds)"
            )
            return data
        }

        private static func audioSegment(
            index: Int,
            segment: DVR.Segment,
            track: DVR.FetchTrack,
            fetcher: DVR.MediaGroupFetcher,
            muxer: Moq.CMAFMuxer,
            started: ContinuousClock.Instant
        ) async throws -> Data {
            var cursor = DVR.TrackCursor(
                name: track.name,
                groups: segment.audioGroups,
                container: track.container,
                fetcher: fetcher
            )
            defer { cursor.cancel() }
            var frames: [Moq.MediaFrame] = []
            var retainedGroups = 0
            while let group = try await cursor.next() {
                retainedGroups += 1
                frames.append(
                    contentsOf: group.frames.lazy.filter {
                        $0.timestampUs >= segment.startTimestampUs
                            && $0.timestampUs < segment.endTimestampUs
                    })
            }
            guard !frames.isEmpty else {
                throw DVR.PlaybackError.segmentUnavailable(.audio, index)
            }
            let data = try muxer.fragment(
                sequence: UInt32(clamping: index + 1),
                frames: frames
            )
            KitLogger.dvr.debug(
                "DVR HLS audio segment ready index=\(index) requestedGroups=\(segment.audioGroups.lowerBound)...\(segment.audioGroups.upperBound) retainedGroups=\(retainedGroups) frames=\(frames.count) bytes=\(data.count) elapsedMs=\(started.duration(to: .now).milliseconds)"
            )
            return data
        }

        func cancel() {
            let tasks = state.withLock { state in
                state.stopped = true
                let tasks = Array(state.tasks.values)
                state.tasks.removeAll()
                return tasks
            }
            for task in tasks {
                task.cancel()
            }
        }
    }
}
