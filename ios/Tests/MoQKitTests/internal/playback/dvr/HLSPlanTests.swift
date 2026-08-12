import XCTest

@testable import MoQKit

final class HLSPlanTests: XCTestCase {
    func testVideoBoundariesCreateSegmentsAndExcludeTrailingSentinel() throws {
        let selection = DVR.Selection(
            video: DVR.TrackSelection(
                name: "video",
                timeline: [
                    .init(group: 10, timestampUs: 10_000_000),
                    .init(group: 11, timestampUs: 11_000_000),
                    .init(group: 12, timestampUs: 12_000_000),
                    .init(group: 13, timestampUs: 13_000_000),
                ]
            ),
            audio: DVR.TrackSelection(
                name: "audio",
                timeline: [
                    .init(group: 100, timestampUs: 9_980_000),
                    .init(group: 150, timestampUs: 10_980_000),
                    .init(group: 200, timestampUs: 11_980_000),
                    .init(group: 250, timestampUs: 12_980_000),
                    .init(group: 251, timestampUs: 13_000_000),
                ]
            )
        )

        let plan = try DVR.HLSPlan(selection: selection)

        XCTAssertEqual(plan.durationUs, 3_000_000)
        XCTAssertEqual(plan.segments.map(\.videoGroup), [10, 11, 12])
        XCTAssertEqual(plan.segments.map(\.startTimestampUs), [10_000_000, 11_000_000, 12_000_000])
        XCTAssertEqual(plan.segments.map(\.endTimestampUs), [11_000_000, 12_000_000, 13_000_000])
        XCTAssertEqual(plan.segments.map(\.audioGroups), [101...150, 151...200, 201...250])
    }

    func testKnownVideoTimelineHoleDoesNotInventAGroup() throws {
        let selection = DVR.Selection(
            video: DVR.TrackSelection(
                name: "video",
                timeline: [
                    .init(group: 20, timestampUs: 20_000_000),
                    .init(group: 22, timestampUs: 22_000_000),
                    .init(group: 23, timestampUs: 23_000_000),
                ]
            ),
            audio: DVR.TrackSelection(
                name: "audio",
                timeline: [
                    .init(group: 400, timestampUs: 20_000_000),
                    .init(group: 500, timestampUs: 22_000_000),
                    .init(group: 550, timestampUs: 23_000_000),
                ]
            )
        )

        let plan = try DVR.HLSPlan(selection: selection)

        XCTAssertEqual(plan.segments.map(\.videoGroup), [20, 22])
        XCTAssertEqual(plan.segments.map(\.durationUs), [2_000_000, 1_000_000])
    }

    func testStaticMediaPlaylistPublishesKnownDurationAndLazySegmentURLs() throws {
        let segments = [
            DVR.Segment(
                index: 0,
                startTimestampUs: 1_000_000,
                endTimestampUs: 2_250_000,
                videoGroup: 7,
                audioGroups: 40...89
            ),
            DVR.Segment(
                index: 1,
                startTimestampUs: 2_250_000,
                endTimestampUs: 3_000_000,
                videoGroup: 8,
                audioGroups: 90...119
            ),
        ]

        let playlist = DVR.HLSManifest.mediaPlaylist(
            kind: .video,
            segments: segments,
            initializationURI: "video-init.mp4"
        )

        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:2"))
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"video-init.mp4\""))
        XCTAssertTrue(playlist.contains("#EXTINF:1.250000,"))
        XCTAssertTrue(playlist.contains("video/0.m4s"))
        XCTAssertTrue(playlist.contains("#EXTINF:0.750000,"))
        XCTAssertTrue(playlist.contains("video/1.m4s"))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }
}
