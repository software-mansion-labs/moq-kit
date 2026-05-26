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

        let stats = tracker.getStats(
            audioLatency: nil,
            videoLatency: nil,
            audioRingBuffer: nil,
            videoJitterBuffer: nil
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

        let stats = tracker.getStats(
            audioLatency: nil,
            videoLatency: nil,
            audioRingBuffer: nil,
            videoJitterBuffer: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.receivedFramesPerSecond ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(arrival.averageInterarrival?.milliseconds ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(arrival.maxInterarrival?.milliseconds ?? 0, 100.0, accuracy: 0.001)
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

        let stats = tracker.getStats(
            audioLatency: nil,
            videoLatency: nil,
            audioRingBuffer: nil,
            videoJitterBuffer: nil
        )

        let arrival = try XCTUnwrap(stats.audioArrival)
        XCTAssertEqual(arrival.slowArrivalCount, 1)
        XCTAssertEqual(arrival.fastArrivalCount, 1)
        XCTAssertEqual(arrival.outOfOrderCount, 1)
        XCTAssertEqual(arrival.maxOutOfOrderDelta?.milliseconds ?? 0, 50.0, accuracy: 0.001)
    }

    func testFrameDiscontinuityResetsBaselineAndTracksGap() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 0))
        tracker.onMediaDiscontinuity(kind: .video, gapUs: 700_000)
        clock.advance(ms: 700)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 700_000, keyframe: true))

        let stats = tracker.getStats(
            audioLatency: nil,
            videoLatency: nil,
            audioRingBuffer: nil,
            videoJitterBuffer: nil
        )

        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.discontinuityCount, 1)
        XCTAssertEqual(arrival.maxDiscontinuityGap?.milliseconds ?? 0, 700.0, accuracy: 0.001)
        XCTAssertEqual(arrival.slowArrivalCount, 0)
        XCTAssertNil(arrival.averageInterarrival)
    }

    func testTrackStartedResetsArrivalBaseline() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.onMediaTrackStarted(kind: .video)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 1_000_000))
        clock.advance(ms: 50)
        tracker.onMediaTrackStarted(kind: .video)
        tracker.onMediaFrame(kind: .video, frame: mediaFrame(timestampUs: 100_000))

        let stats = tracker.getStats(
            audioLatency: nil,
            videoLatency: nil,
            audioRingBuffer: nil,
            videoJitterBuffer: nil
        )

        // Track baseline was reset on the second `onMediaTrackStarted`, so the
        // 1_000_000us → 100_000us PTS regression is not compared as out-of-order.
        let arrival = try XCTUnwrap(stats.videoArrival)
        XCTAssertEqual(arrival.outOfOrderCount, 0)
        XCTAssertNil(arrival.averageInterarrival)
    }
}

final class PlaybackStatsTrackerLifecycleTests: XCTestCase {
    func testTimeToFirstFrameAndPlayingAreRecordedFromSession() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        tracker.beginSession(rebufferKind: .audio)

        tracker.emitTrackReady(
            kind: .audio,
            trackName: "audio",
            trackEpoch: 1,
            sourceTimestampUs: 0,
            targetBuffering: .milliseconds(100),
            keyframe: false,
            payloadBytes: 64
        )
        tracker.armAudioPlaybackStart(
            trackName: "audio",
            sourceTimestampUs: 0,
            targetBuffering: .milliseconds(100),
            trackEpoch: 1
        )
        tracker.audioPlaybackStarted(
            timestampUs: 0,
            hostTime: nil
        )

        let stats = tracker.currentStats()
        XCTAssertNotNil(stats.timeToFirst.audioFrame)
        XCTAssertNotNil(stats.timeToFirst.audioPlaying)
        XCTAssertNotNil(stats.audioStalls)
        XCTAssertNil(stats.videoStalls)
    }

    func testPlaybackStartFiresOnceForRebufferKind() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        defer { subscription.cancel() }

        tracker.beginSession(rebufferKind: .audio)

        // Video starts playing first — must not emit playbackStart because rebufferKind=audio.
        tracker.videoPlaybackStarted(
            context: PlaybackStartContext(
                kind: .video, trackName: "video", sourceTimestampUs: 0,
                targetBuffering: .milliseconds(100), trackEpoch: 1
            ),
            presentationTimeUs: 0,
            clockTimeUs: 0,
            buffer: .zero
        )
        XCTAssertFalse(recorder.names.contains(.playbackStart))

        tracker.armAudioPlaybackStart(
            trackName: "audio",
            sourceTimestampUs: 0,
            targetBuffering: .milliseconds(100),
            trackEpoch: 1
        )
        tracker.audioPlaybackStarted(
            timestampUs: 0,
            hostTime: nil
        )

        XCTAssertEqual(recorder.names.filter { $0 == .playbackStart }.count, 1)
    }

    func testStallLifecycleProducesStallAndRebufferEvents() {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)
        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        defer { subscription.cancel() }

        tracker.beginSession(rebufferKind: .audio)

        // First playing call seeds readyAt so stall stats can be reported.
        tracker.armAudioPlaybackStart(
            trackName: "audio", sourceTimestampUs: 0,
            targetBuffering: .milliseconds(100), trackEpoch: 1
        )
        tracker.audioPlaybackStarted(
            timestampUs: 0, hostTime: nil
        )

        tracker.noteStall(kind: .audio, stalled: true)
        tracker.noteStall(kind: .audio, stalled: true) // de-duped
        tracker.noteStall(kind: .audio, stalled: false)

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

    func testCloseOutInFlightStallsDoesNotCreateIdleStallStats() {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.beginSession(rebufferKind: .audio)
        tracker.closeOutInFlightStalls()

        XCTAssertNil(tracker.currentStats().audioStalls)
    }

    func testCloseOutInFlightStallsEndsActiveStall() throws {
        let clock = TestPlaybackWallClock()
        let tracker = makeTracker(clock: clock)

        tracker.beginSession(rebufferKind: .audio)
        tracker.armAudioPlaybackStart(
            trackName: "audio", sourceTimestampUs: 0,
            targetBuffering: .milliseconds(100), trackEpoch: 1
        )
        tracker.audioPlaybackStarted(
            timestampUs: 0, hostTime: nil
        )

        tracker.noteStall(kind: .audio, stalled: true)
        clock.advance(ms: 250)
        tracker.closeOutInFlightStalls()

        let stats = try XCTUnwrap(tracker.currentStats().audioStalls)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.totalDuration.milliseconds, 250, accuracy: 0.001)
    }

    func testSwitchLifecycleAggregatesMilestones() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        tracker.beginSession(rebufferKind: .video)

        tracker.emitSubscribeStart(kind: .video, trackName: "video-high", trackEpoch: 2)
        tracker.emitTrackReady(
            kind: .video, trackName: "video-high", trackEpoch: 2,
            sourceTimestampUs: 0, targetBuffering: .milliseconds(100), keyframe: true, payloadBytes: 64
        )
        tracker.videoPlaybackStarted(
            context: PlaybackStartContext(
                kind: .video, trackName: "video-high", sourceTimestampUs: 0,
                targetBuffering: .milliseconds(100), trackEpoch: 2
            ),
            presentationTimeUs: 0,
            clockTimeUs: 0,
            buffer: .zero
        )
        tracker.emitTrackSwitch(kind: .video, trackName: "video-high", trackEpoch: 2)

        let switches = try XCTUnwrap(tracker.currentStats().videoSwitches)
        let latest = try XCTUnwrap(switches.latest)
        XCTAssertEqual(switches.requestedCount, 1)
        XCTAssertEqual(switches.completedCount, 1)
        XCTAssertEqual(latest.trackName, "video-high")
        XCTAssertTrue(latest.isCompleted)
        XCTAssertNotNil(latest.switchToReady)
        XCTAssertNotNil(latest.readyToPlaying)
        XCTAssertNotNil(latest.switchToActive)
    }

    func testFailedSwitchRecordsErrorWithoutCompletion() throws {
        let hub = PlayerEventHub()
        let tracker = PlaybackStatsTracker(events: hub)

        tracker.beginSession(rebufferKind: .audio)
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
        hub.emit(.playerInit(sessionEvent()))

        let recorder = EventRecorder()
        let subscription = hub.subscribeInternal { recorder.record($0) }
        hub.emit(.playbackRequest(sessionEvent()))

        XCTAssertEqual(recorder.names, [.playbackRequest])
        subscription.cancel()
    }

    func testSequenceNumbersIncrement() {
        let hub = PlayerEventHub()

        let first = hub.emit(.playerInit(sessionEvent()))
        let second = hub.emit(.playbackRequest(sessionEvent()))

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

private func sessionEvent() -> PlayerSessionEvent {
    PlayerSessionEvent(
        catalogPath: "catalog",
        targetBuffering: .milliseconds(100),
        videoTrackName: nil,
        audioTrackName: nil
    )
}

private func mediaFrame(
    payloadSize: Int = 1,
    timestampUs: UInt64,
    keyframe: Bool = false
) -> MediaFrame {
    MediaFrame(payload: Data(repeating: 0, count: payloadSize), timestampUs: timestampUs, keyframe: keyframe)
}
