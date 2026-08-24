import Foundation
import Moq
import os

extension DVR {
    struct FetchTrack: Sendable {
        let name: String
        let container: Moq.Container
        let configuration: DVR.FetchTrackConfiguration

        init(name: String, config: Moq.Video) {
            self.name = name
            self.container = config.container
            self.configuration = .video(config)
        }

        init(name: String, config: Moq.Audio) {
            self.name = name
            self.container = config.container
            self.configuration = .audio(config)
        }
    }

    enum FetchTrackConfiguration: Sendable {
        case video(Moq.Video)
        case audio(Moq.Audio)
    }

    struct FetchGroup: Sendable {
        let frames: [Moq.MediaFrame]
        let groupSequence: UInt64
    }

    struct MediaGroupFetcher: Sendable {
        let fetch: @Sendable (String, UInt64, Moq.Container) async throws -> [Moq.MediaFrame]

        init(
            fetch: @escaping @Sendable (String, UInt64, Moq.Container) async throws -> [Moq.MediaFrame]
        ) {
            self.fetch = fetch
        }

        init(broadcast: Moq.BroadcastConsumer) {
            self.fetch = { name, sequence, container in
                KitLogger.dvr.debug(
                    "DVR group FETCH starting track=\(name, privacy: .public) group=\(sequence) container=\(container.moqKitDescription, privacy: .public)"
                )
                let consumer = try await broadcast.fetchMediaGroup(
                    name: name,
                    sequence: sequence,
                    container: container
                )
                defer { consumer.cancel() }

                var frames: [Moq.MediaFrame] = []
                while let frame = try await consumer.next() {
                    try Task.checkCancellation()
                    frames.append(frame)
                }
                if let first = frames.first, let last = frames.last {
                    KitLogger.dvr.debug(
                        "DVR group FETCH completed track=\(name, privacy: .public) group=\(sequence) frames=\(frames.count) firstTimestampUs=\(first.timestampUs) lastTimestampUs=\(last.timestampUs) firstKeyframe=\(first.keyframe)"
                    )
                } else {
                    KitLogger.dvr.debug(
                        "DVR group FETCH completed empty track=\(name, privacy: .public) group=\(sequence)"
                    )
                }
                return frames
            }
        }
    }

    struct TrackCursor {
        let name: String
        let groups: ClosedRange<UInt64>
        let container: Moq.Container
        let fetcher: DVR.MediaGroupFetcher

        private let prefetchLimit: Int
        private var nextSequenceToSchedule: UInt64?
        private var nextSequenceToConsume: UInt64?
        private var pendingGroups: [UInt64: Task<[Moq.MediaFrame], Error>] = [:]

        init(
            name: String,
            groups: ClosedRange<UInt64>,
            container: Moq.Container,
            fetcher: DVR.MediaGroupFetcher,
            prefetchLimit: Int = 16
        ) {
            precondition(prefetchLimit > 0)
            self.name = name
            self.groups = groups
            self.container = container
            self.fetcher = fetcher
            self.prefetchLimit = prefetchLimit
            self.nextSequenceToSchedule = groups.lowerBound
            self.nextSequenceToConsume = groups.lowerBound
            fillPrefetchWindow()
        }

        mutating func next() async throws -> DVR.FetchGroup? {
            while true {
                try Task.checkCancellation()

                guard let sequence = nextSequenceToConsume,
                    let task = pendingGroups.removeValue(forKey: sequence)
                else { return nil }
                nextSequenceToConsume = following(sequence)

                do {
                    let frames = try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    fillPrefetchWindow()
                    guard !frames.isEmpty else { continue }
                    return DVR.FetchGroup(frames: frames, groupSequence: sequence)
                } catch {
                    guard Self.isUnavailableGroup(error) else { throw error }
                    // Retention is allowed to leave holes inside a requested DVR window.
                    let trackName = self.name
                    KitLogger.dvr.debug(
                        "DVR group unavailable; skipping track=\(trackName, privacy: .public) group=\(sequence)"
                    )
                    fillPrefetchWindow()
                }
            }
        }

        mutating func cancel() {
            for task in pendingGroups.values {
                task.cancel()
            }
            pendingGroups.removeAll()
        }

        private mutating func fillPrefetchWindow() {
            while pendingGroups.count < prefetchLimit,
                let sequence = nextSequenceToSchedule
            {
                let name = self.name
                let container = container
                let fetcher = fetcher
                pendingGroups[sequence] = Task {
                    try await fetcher.fetch(name, sequence, container)
                }
                nextSequenceToSchedule = following(sequence)
            }
        }

        private func following(_ sequence: UInt64) -> UInt64? {
            sequence == groups.upperBound ? nil : sequence + 1
        }

        private static func isUnavailableGroup(_ error: Error) -> Bool {
            switch error {
            case MoqError.NotFound:
                return true
            case MoqError.Mux(message: let message):
                return message.hasSuffix("remote error: code=13")
            default:
                return false
            }
        }
    }

    enum PlaybackError: LocalizedError {
        case invalidTrackConfiguration
        case segmentUnavailable(DVR.MediaKind, Int)

        var errorDescription: String? {
            switch self {
            case .invalidTrackConfiguration:
                return "The DVR remuxer received mismatched audio/video track metadata"
            case .segmentUnavailable(let kind, let index):
                return "DVR \(kind.rawValue) segment \(index) is no longer retained"
            }
        }
    }
}
