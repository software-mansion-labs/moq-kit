import XCTest

@testable import MoQKit

final class TimelineResolverTests: XCTestCase {
    func testSelectionResolvesVideoSteeredWindowWithAudioCoverage() async throws {
        let resolver = DVR.TimelineResolver(
            videoTrackName: "video.m4s",
            audioTrackName: "audio.m4s",
            videoEntries: points(groups: 10...14, startingAtUs: 10_000_000, intervalUs: 1_000_000),
            audioEntries: points(groups: 100...108, startingAtUs: 10_000_000, intervalUs: 500_000)
        )

        let selection = try await resolver.selection(for: .seconds(2))

        XCTAssertEqual(
            selection,
            DVR.Selection(
                video: DVR.TrackSelection(
                    name: "video.m4s",
                    timeline: points(
                        groups: 12...14,
                        startingAtUs: 12_000_000,
                        intervalUs: 1_000_000
                    )
                ),
                audio: DVR.TrackSelection(
                    name: "audio.m4s",
                    timeline: points(
                        groups: 104...108,
                        startingAtUs: 12_000_000,
                        intervalUs: 500_000
                    )
                )
            )
        )
    }

    func testSelectionRejectsEmptyTimelines() async {
        let resolver = DVR.TimelineResolver(
            videoTrackName: "video.m4s",
            audioTrackName: "audio.m4s",
            videoEntries: [],
            audioEntries: []
        )

        await assertInvalidConfiguration(
            "DVR timelines have not produced entries yet",
            from: resolver
        )
    }

    func testSelectionRejectsAudioTimelineWithoutSubWindowCoverage() async {
        let resolver = DVR.TimelineResolver(
            videoTrackName: "video.m4s",
            audioTrackName: "audio.m4s",
            videoEntries: points(groups: 10...12, startingAtUs: 10_000_000, intervalUs: 1_000_000),
            audioEntries: [DVR.TimelinePoint(group: 100, timestampUs: 12_000_000)]
        )

        await assertInvalidConfiguration(
            "The audio timeline does not cover the video DVR window",
            from: resolver
        )
    }

    func testSelectionRejectsWindowWithoutOneCompleteVideoGOP() async {
        let resolver = DVR.TimelineResolver(
            videoTrackName: "video.m4s",
            audioTrackName: "audio.m4s",
            videoEntries: points(groups: 10...12, startingAtUs: 10_000_000, intervalUs: 1_000_000),
            audioEntries: [
                DVR.TimelinePoint(group: 100, timestampUs: 10_000_000),
                DVR.TimelinePoint(group: 101, timestampUs: 11_900_000),
            ]
        )

        await assertInvalidConfiguration(
            "DVR selection needs at least one complete video GOP",
            from: resolver,
            duration: .milliseconds(100)
        )
    }

    func testSelectionKeepsVideoEndSentinelAndAudioCoverage() {
        let entries = [
            DVR.TimelineEntry(group: 40, timestampUs: 10_000_000),
            DVR.TimelineEntry(group: 44, timestampUs: 12_000_000),
            DVR.TimelineEntry(group: 48, timestampUs: 14_000_000),
            DVR.TimelineEntry(group: 52, timestampUs: 16_000_000),
        ]

        XCTAssertEqual(
            DVR.TimelineIndex.slice(in: entries, start: 11_000_000, end: 15_000_000),
            [
                DVR.TimelineEntry(group: 40, timestampUs: 10_000_000),
                DVR.TimelineEntry(group: 44, timestampUs: 12_000_000),
                DVR.TimelineEntry(group: 48, timestampUs: 14_000_000),
                DVR.TimelineEntry(group: 52, timestampUs: 16_000_000),
            ])
    }

    func testAppendIgnoresOlderEntriesReplacesDuplicatesAndBoundsMemory() {
        var entries: [DVR.TimelineEntry] = []
        for entry in [
            DVR.TimelineEntry(group: 1, timestampUs: 1_000),
            DVR.TimelineEntry(group: 2, timestampUs: 2_000),
            DVR.TimelineEntry(group: 2, timestampUs: 2_100),
            DVR.TimelineEntry(group: 1, timestampUs: 1_100),
            DVR.TimelineEntry(group: 3, timestampUs: 3_000),
        ] {
            DVR.TimelineIndex.append(entry, to: &entries, limit: 2)
        }

        XCTAssertEqual(
            entries,
            [
                DVR.TimelineEntry(group: 2, timestampUs: 2_100),
                DVR.TimelineEntry(group: 3, timestampUs: 3_000),
            ]
        )
    }

    private func points(
        groups: ClosedRange<UInt64>,
        startingAtUs: UInt64,
        intervalUs: UInt64
    ) -> [DVR.TimelinePoint] {
        groups.enumerated().map { offset, group in
            DVR.TimelinePoint(
                group: group,
                timestampUs: startingAtUs + UInt64(offset) * intervalUs
            )
        }
    }

    private func assertInvalidConfiguration(
        _ message: String,
        from resolver: DVR.TimelineResolver,
        duration: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await resolver.selection(for: duration)
            XCTFail("Expected selection to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SessionError,
                .invalidConfiguration(message),
                file: file,
                line: line
            )
        }
    }
}
