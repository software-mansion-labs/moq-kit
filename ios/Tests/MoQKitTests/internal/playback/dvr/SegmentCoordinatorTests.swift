import Foundation
import Moq
import XCTest

@testable import MoQKit

final class SegmentCoordinatorTests: XCTestCase {
    func testRequestedSegmentsFetchOnlyTheirMappedMediaGroupsAndDeduplicate() async throws {
        let plan = try DVR.HLSPlan(
            selection: DVR.Selection(
                video: DVR.TrackSelection(
                    name: "video",
                    timeline: [
                        .init(group: 10, timestampUs: 10_000_000),
                        .init(group: 11, timestampUs: 11_000_000),
                        .init(group: 12, timestampUs: 12_000_000),
                    ]),
                audio: DVR.TrackSelection(
                    name: "audio",
                    timeline: [
                        .init(group: 100, timestampUs: 10_000_000),
                        .init(group: 101, timestampUs: 11_000_000),
                        .init(group: 102, timestampUs: 12_000_000),
                    ])
            ))
        let requests = SegmentRequests()
        let fetcher = DVR.MediaGroupFetcher { track, group, _ in
            await requests.append(track: track, group: group)
            try await Task.sleep(for: .milliseconds(20))
            if track == "video" {
                return [
                    Moq.MediaFrame(payload: Data("key".utf8), timestampUs: 11_000_000, keyframe: true),
                    Moq.MediaFrame(payload: Data("delta".utf8), timestampUs: 11_033_000, keyframe: false),
                ]
            }
            return [Moq.MediaFrame(payload: Data([0x78, 0x00]), timestampUs: 11_020_000, keyframe: true)]
        }
        let coordinator = try DVR.SegmentCoordinator(
            plan: plan,
            video: DVR.FetchTrack(
                name: "video",
                config: Self.videoConfig
            ),
            audio: DVR.FetchTrack(
                name: "audio",
                config: Self.audioConfig
            ),
            fetcher: fetcher
        )

        async let firstVideo = coordinator.segment(kind: .video, index: 1)
        async let duplicateVideo = coordinator.segment(kind: .video, index: 1)
        let videoSegments = try await (firstVideo, duplicateVideo)
        let audioSegment = try await coordinator.segment(kind: .audio, index: 1)

        XCTAssertEqual(videoSegments.0, videoSegments.1)
        XCTAssertEqual(videoSegments.0.subdata(in: 4..<8), Data("moof".utf8))
        XCTAssertEqual(audioSegment.subdata(in: 4..<8), Data("moof".utf8))
        let values = await requests.values
        XCTAssertEqual(values.filter { $0.track == "video" }.map(\.group), [11])
        XCTAssertEqual(values.filter { $0.track == "audio" }.map(\.group), [101])
    }

    private static let videoConfig = Moq.Video(
        codec: "vp09.00.10.08",
        description: nil,
        coded: nil,
        displayAspect: nil,
        bitrate: nil,
        framerate: 30,
        container: .legacy,
        timeline: nil
    )

    private static let audioConfig = Moq.Audio(
        codec: "opus",
        description: nil,
        sampleRate: 48_000,
        channelCount: 2,
        bitrate: nil,
        container: .legacy,
        timeline: nil
    )
}

private actor SegmentRequests {
    struct Value: Sendable {
        let track: String
        let group: UInt64
    }

    private(set) var values: [Value] = []

    func append(track: String, group: UInt64) {
        values.append(Value(track: track, group: group))
    }
}
