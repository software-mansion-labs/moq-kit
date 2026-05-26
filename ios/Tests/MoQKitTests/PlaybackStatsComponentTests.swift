@testable import MoQKit
import Foundation
import XCTest

final class PlaybackSampleStatsComponentTests: XCTestCase {
    func testSampleStatsReportsBitrateArrivalAndDrops() throws {
        var stats = PlaybackSampleStats()

        stats.onMediaFrame(
            kind: .audio,
            frame: componentMediaFrame(payloadSize: 100, timestampUs: 0),
            now: 0
        )
        stats.onMediaFrame(
            kind: .audio,
            frame: componentMediaFrame(payloadSize: 100, timestampUs: 200_000),
            now: 200_000_000
        )
        stats.recordAudioFramesDropped(2)

        let snapshot = stats.snapshot(now: 200_000_000)

        XCTAssertEqual(snapshot.audioBitrateKbps ?? 0, 8.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.audioFramesDropped, 2)
        XCTAssertNotNil(snapshot.audioArrival)
        XCTAssertNil(snapshot.videoBitrateKbps)
    }

    func testSampleStatsDiscontinuityResetsArrivalBaseline() throws {
        var stats = PlaybackSampleStats()

        stats.onMediaFrame(
            kind: .video,
            frame: componentMediaFrame(timestampUs: 1_000_000),
            now: 0
        )
        stats.onMediaDiscontinuity(kind: .video, gapUs: 700_000)
        stats.onMediaFrame(
            kind: .video,
            frame: componentMediaFrame(timestampUs: 100_000),
            now: 700_000_000
        )

        let arrival = try XCTUnwrap(stats.snapshot(now: 700_000_000).videoArrival)
        XCTAssertEqual(arrival.discontinuityCount, 1)
        XCTAssertEqual(arrival.outOfOrderCount, 0)
        XCTAssertNil(arrival.averageInterarrival)
    }
}

final class PlaybackLifecycleStateComponentTests: XCTestCase {
    func testStallLifecycleDedupesAndReportsRebufferChange() throws {
        let clock = ContinuousClock()
        let instant = clock.now
        var lifecycle = PlaybackLifecycleState()

        lifecycle.beginSession(rebufferKind: .audio, at: instant)

        let start = try XCTUnwrap(
            lifecycle.recordStall(kind: .audio, stalled: true, at: instant)
        )
        XCTAssertTrue(start.stalled)
        XCTAssertTrue(start.rebufferChanged)
        XCTAssertNil(lifecycle.recordStall(kind: .audio, stalled: true, at: instant))

        let end = try XCTUnwrap(
            lifecycle.recordStall(kind: .audio, stalled: false, at: instant)
        )
        XCTAssertFalse(end.stalled)
        XCTAssertTrue(end.rebufferChanged)

        let snapshot = lifecycle.snapshot(at: instant)
        XCTAssertEqual(snapshot.audioStalls?.count, 1)
    }

    func testTrackSwitchLifecycleAggregatesMilestones() throws {
        let clock = ContinuousClock()
        let instant = clock.now
        var lifecycle = PlaybackLifecycleState()

        lifecycle.beginSession(rebufferKind: .video, at: instant)
        lifecycle.recordSubscribeStart(
            kind: .video,
            trackName: "video-high",
            trackEpoch: 2,
            at: instant
        )
        lifecycle.recordTrackReady(kind: .video, trackEpoch: 2, at: instant)
        lifecycle.recordSwitchPlaying(
            context: PlaybackStartContext(
                kind: .video,
                trackName: "video-high",
                sourceTimestampUs: 0,
                targetBuffering: .milliseconds(100),
                trackEpoch: 2
            ),
            at: instant
        )
        lifecycle.recordTrackSwitch(kind: .video, at: instant)

        let switches = try XCTUnwrap(lifecycle.snapshot(at: instant).videoSwitches)
        let latest = try XCTUnwrap(switches.latest)
        XCTAssertEqual(switches.requestedCount, 1)
        XCTAssertEqual(switches.completedCount, 1)
        XCTAssertEqual(latest.trackName, "video-high")
        XCTAssertTrue(latest.isCompleted)
        XCTAssertNotNil(latest.switchToReady)
        XCTAssertNotNil(latest.readyToPlaying)
        XCTAssertNotNil(latest.switchToActive)
    }
}

final class AudioPlaybackStartHandoffTests: XCTestCase {
    func testConsumesExpectedAudioStartOnceTimestampReachesSource() throws {
        let handoff = AudioPlaybackStartHandoff()

        handoff.prepare(playbackStartContext(sourceTimestampUs: 1_000))

        XCTAssertTrue(handoff.hasPendingPlaybackStart)
        XCTAssertNil(handoff.consumeIfRendered(timestampUs: 999))
        XCTAssertTrue(handoff.hasPendingPlaybackStart)

        let context = try XCTUnwrap(handoff.consumeIfRendered(timestampUs: 1_000))
        XCTAssertEqual(context.trackName, "audio")
        XCTAssertFalse(handoff.hasPendingPlaybackStart)
        XCTAssertNil(handoff.consumeIfRendered(timestampUs: 1_000))
    }

    func testClearDisarmsExpectedAudioStart() {
        let handoff = AudioPlaybackStartHandoff()

        handoff.prepare(playbackStartContext(sourceTimestampUs: 1_000))
        handoff.clear()

        XCTAssertFalse(handoff.hasPendingPlaybackStart)
        XCTAssertNil(handoff.consumeIfRendered(timestampUs: 1_000))
    }

    func testPrepareReplacesPendingAudioStart() throws {
        let handoff = AudioPlaybackStartHandoff()

        handoff.prepare(playbackStartContext(trackName: "audio-old", sourceTimestampUs: 1_000))
        handoff.prepare(playbackStartContext(trackName: "audio-new", sourceTimestampUs: 2_000))

        XCTAssertNil(handoff.consumeIfRendered(timestampUs: 1_500))
        XCTAssertTrue(handoff.hasPendingPlaybackStart)

        let context = try XCTUnwrap(handoff.consumeIfRendered(timestampUs: 2_000))
        XCTAssertEqual(context.trackName, "audio-new")
        XCTAssertFalse(handoff.hasPendingPlaybackStart)
    }
}

private func playbackStartContext(
    trackName: String = "audio",
    sourceTimestampUs: UInt64,
    targetBuffering: Duration = .milliseconds(100),
    trackEpoch: TrackEpoch = 1
) -> PlaybackStartContext {
    PlaybackStartContext(
        kind: .audio,
        trackName: trackName,
        sourceTimestampUs: sourceTimestampUs,
        targetBuffering: targetBuffering,
        trackEpoch: trackEpoch
    )
}

private func componentMediaFrame(
    payloadSize: Int = 1,
    timestampUs: UInt64,
    keyframe: Bool = false
) -> MediaFrame {
    MediaFrame(payload: Data(repeating: 0, count: payloadSize), timestampUs: timestampUs, keyframe: keyframe)
}
