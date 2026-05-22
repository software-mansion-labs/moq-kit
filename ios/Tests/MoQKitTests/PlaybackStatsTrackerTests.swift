@testable import MoQKit
import Foundation
import XCTest

final class PlaybackStatsTrackerSampleTests: XCTestCase {
    func testReceivedBytesProduceAudioBitrate() {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(payloadSize: 100, timestampUs: 0))
        clock.advance(ms: 200)
        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(payloadSize: 100, timestampUs: 200_000))

        let stats = tracker.sampleStats(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        XCTAssertEqual(stats.audioBitrateKbps ?? 0, 8.0, accuracy: 0.001)
        XCTAssertNil(stats.videoBitrateKbps)
    }

    func testArrivalWindowReportsReceivedFpsAndInterarrivalTiming() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 0))
        clock.advance(ms: 100)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 100_000))
        clock.advance(ms: 100)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 200_000))

        let stats = tracker.sampleStats(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.receivedFramesPerSecond ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(arrival.averageInterarrivalMs ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(arrival.maxInterarrivalMs ?? 0, 100.0, accuracy: 0.001)
    }

    func testArrivalDiagnosticsTrackSlowFastAndOutOfOrderFrames() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(timestampUs: 0))
        clock.advance(ms: 100)
        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(timestampUs: 100_000))
        clock.advance(ms: 250)
        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(timestampUs: 200_000))
        clock.advance(ms: 10)
        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(timestampUs: 300_000))
        clock.advance(ms: 10)
        tracker.onMediaFrame(kind: .audio, frame: mediaFrame(timestampUs: 250_000))

        let stats = tracker.sampleStats(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.audioArrival)
        XCTAssertEqual(arrival.slowArrivalCount, 1)
        XCTAssertEqual(arrival.fastArrivalCount, 1)
        XCTAssertEqual(arrival.outOfOrderCount, 1)
        XCTAssertEqual(arrival.maxOutOfOrderDeltaMs ?? 0, 50.0, accuracy: 0.001)
    }

    func testFrameDiscontinuityResetsBaselineAndTracksGap() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 0))
        tracker.onMediaDiscontinuity(kind: .video, gapUs: 700_000)
        clock.advance(ms: 700)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 700_000, keyframe: true))

        let stats = tracker.sampleStats(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.discontinuityCount, 1)
        XCTAssertEqual(arrival.maxDiscontinuityGapMs ?? 0, 700.0, accuracy: 0.001)
        XCTAssertEqual(arrival.slowArrivalCount, 0)
        XCTAssertNil(arrival.averageInterarrivalMs)
    }

    func testTrackStartedResetsArrivalBaseline() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaTrackStarted(kind: .video)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 1_000_000))
        clock.advance(ms: 50)
        tracker.onMediaTrackStarted(kind: .video)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 100_000))

        let stats = tracker.sampleStats(
            audioLatencyMs: nil,
            videoLatencyMs: nil,
            audioRingBufferMs: nil,
            videoJitterBufferMs: nil
        )

        // Track baseline was reset on the second `onMediaTrackStarted`, so the
        // 1_000_000us → 100_000us PTS regression is not compared as out-of-order.
        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.outOfOrderCount, 0)
        XCTAssertNil(arrival.averageInterarrivalMs)
    }
}

final class PlaybackStatsTrackerLifecycleTests: XCTestCase {
    func testTimeToFirstFrameAndPlayingAreRecordedFromSession() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        let session = PlayerEventHub.timestampMs()
        tracker.beginSession(rebufferKind: .audio, at: session)

        tracker.emitTrackReady(
            kind: .audio,
            trackName: "audio",
            trackEpoch: 1,
            sourceTimestampUs: 0,
            targetBufferingMs: 100,
            keyframe: false,
            payloadBytes: 64
        )
        tracker.expectAudioPlaybackStart(
            trackName: "audio",
            sourceTimestampUs: 0,
            targetBufferingMs: 100,
            trackEpoch: 1
        )
        tracker.audioPlaybackStartedIfExpected(
            renderedTimestampUs: 0,
            outputHostTime: nil,
            outputPresentationLatencyMs: nil
        )

        let stats = tracker.currentStats()
        XCTAssertNotNil(stats.timeToFirst.audioFrameMs)
        XCTAssertNotNil(stats.timeToFirst.audioPlayingMs)
        XCTAssertNotNil(stats.audioStalls)
        XCTAssertNil(stats.videoStalls)
    }

    func testPlaybackStartFiresOnceForRebufferKind() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        defer { subscription.cancel() }

        tracker.beginSession(rebufferKind: .audio, at: PlayerEventHub.timestampMs())

        // Video starts playing first — must not emit playbackStart because rebufferKind=audio.
        tracker.videoPlaybackStarted(
            context: PlaybackStartContext(
                kind: .video, trackName: "video", sourceTimestampUs: 0,
                targetBufferingMs: 100, trackEpoch: 1
            ),
            presentationTimeUs: 0,
            clockTimeUs: 0,
            bufferMs: 0
        )
        XCTAssertFalse(recorder.names.contains(.playbackStart))

        tracker.expectAudioPlaybackStart(
            trackName: "audio",
            sourceTimestampUs: 0,
            targetBufferingMs: 100,
            trackEpoch: 1
        )
        tracker.audioPlaybackStartedIfExpected(
            renderedTimestampUs: 0,
            outputHostTime: nil,
            outputPresentationLatencyMs: nil
        )

        XCTAssertEqual(recorder.names.filter { $0 == .playbackStart }.count, 1)
    }

    func testStallLifecycleProducesStallAndRebufferEvents() {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)
        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        defer { subscription.cancel() }

        tracker.beginSession(rebufferKind: .audio, at: PlayerEventHub.timestampMs())

        // First playing call seeds readyAtMs so stall stats can be reported.
        tracker.expectAudioPlaybackStart(
            trackName: "audio", sourceTimestampUs: 0,
            targetBufferingMs: 100, trackEpoch: 1
        )
        tracker.audioPlaybackStartedIfExpected(
            renderedTimestampUs: 0, outputHostTime: nil, outputPresentationLatencyMs: nil
        )

        tracker.audioStallBegan()
        tracker.audioStallBegan() // de-duped
        tracker.audioStallEnded()

        XCTAssertEqual(
            recorder.names.filter { $0 == .trackStallStart || $0 == .trackStallEnd }.count,
            2
        )
        XCTAssertEqual(
            recorder.names.filter { $0 == .rebufferStart || $0 == .rebufferEnd }.count,
            2
        )
        let stats = tracker.currentStats()
        XCTAssertEqual(stats.audioStalls?.count, 1)
    }

    func testSwitchLifecycleAggregatesMilestones() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        tracker.beginSession(rebufferKind: .video, at: PlayerEventHub.timestampMs())

        tracker.emitSubscribeStart(kind: .video, trackName: "video-high", trackEpoch: 2)
        tracker.emitTrackReady(
            kind: .video, trackName: "video-high", trackEpoch: 2,
            sourceTimestampUs: 0, targetBufferingMs: 100, keyframe: true, payloadBytes: 64
        )
        tracker.videoPlaybackStarted(
            context: PlaybackStartContext(
                kind: .video, trackName: "video-high", sourceTimestampUs: 0,
                targetBufferingMs: 100, trackEpoch: 2
            ),
            presentationTimeUs: 0,
            clockTimeUs: 0,
            bufferMs: 0
        )
        tracker.emitTrackSwitch(kind: .video, trackName: "video-high", trackEpoch: 2)

        let switches = try XCTUnwrap(tracker.currentStats().videoSwitches)
        let latest = try XCTUnwrap(switches.latest)
        XCTAssertEqual(switches.requestedCount, 1)
        XCTAssertEqual(switches.completedCount, 1)
        XCTAssertEqual(latest.trackName, "video-high")
        XCTAssertTrue(latest.isCompleted)
        XCTAssertNotNil(latest.switchToReadyMs)
        XCTAssertNotNil(latest.readyToPlayingMs)
        XCTAssertNotNil(latest.switchToActiveMs)
    }

    func testFailedSwitchRecordsErrorWithoutCompletion() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        tracker.beginSession(rebufferKind: .audio, at: PlayerEventHub.timestampMs())
        tracker.emitSubscribeStart(kind: .audio, trackName: "audio-alt", trackEpoch: 2)
        tracker.emitSubscribeError(
            kind: .audio, trackName: "audio-alt",
            message: "subscribe failed", trackEpoch: 2
        )

        let switches = try XCTUnwrap(tracker.currentStats().audioSwitches)
        let latest = try XCTUnwrap(switches.latest)
        XCTAssertEqual(switches.requestedCount, 1)
        XCTAssertEqual(switches.completedCount, 0)
        XCTAssertFalse(latest.isCompleted)
        XCTAssertEqual(latest.errorMessage, "subscribe failed")
    }

    func testSubscribeStatsSkipsInitialEmptyEmit() {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        let expectation = XCTestExpectation(description: "no initial emit")
        expectation.isInverted = true
        let subscription = tracker.subscribeStats { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.05)
        subscription.cancel()
    }
}

final class PlayerEventHubTests: XCTestCase {
    func testSubscribeInternalDoesNotReplayPastEvents() {
        let hub = PlayerEventHub()
        hub.emit(.playerInit)

        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        hub.emit(.playbackRequest)

        XCTAssertEqual(recorder.names, [.playbackRequest])
        subscription.cancel()
    }

    func testSequenceNumbersIncrement() {
        let hub = PlayerEventHub()

        let first = hub.emit(.playerInit)
        let second = hub.emit(.playbackRequest)

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
    }
}

final class PlayerEventNameTests: XCTestCase {
    func testTrackEventRawValues() {
        XCTAssertEqual(PlayerEventName.trackReady.rawValue, "track.ready")
        XCTAssertEqual(PlayerEventName.trackSwitch.rawValue, "track.switch")
        XCTAssertEqual(PlayerEventName.trackPlaying.rawValue, "track.playing")
        XCTAssertEqual(PlayerEventName.decodeError.rawValue, "decode.error")
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = UnfairLock()
    private var events: [PlayerEvent] = []

    var names: [PlayerEventName] {
        lock.withLock { events.map(\.name) }
    }

    func record(_ event: PlayerEvent) {
        lock.withLock { events.append(event) }
    }
}

private func makeTracker(clock: TestPlaybackWallClock) -> PlaybackStatsTracker {
    PlaybackStatsTracker(events: PlayerEventHub(), wallClock: clock)
}

private func mediaFrame(
    payloadSize: Int = 1,
    timestampUs: UInt64,
    keyframe: Bool = false
) -> MediaFrame {
    MediaFrame(payload: Data(repeating: 0, count: payloadSize), timestampUs: timestampUs, keyframe: keyframe)
}
