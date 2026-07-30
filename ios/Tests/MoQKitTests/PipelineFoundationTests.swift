@testable import MoQKit
import Foundation
import XCTest

final class PipelineFoundationTests: XCTestCase {
    func testPipelineBusDeliversEventsWithoutReplayingEarlierEvents() async throws {
        let bus = PipelineBus(capacity: 2)
        let context = PipelineContext(
            trackId: "video",
            mediaKind: .video,
            timestampNanos: 1
        )

        bus.emit(.frameArrived(
            context: context,
            ptsUs: 10,
            groupSequence: nil,
            frameIndex: nil,
            bytes: 100
        ))

        let stream = bus.events()
        bus.emit(.frameAdmitted(
            context: context,
            ptsUs: 10,
            bufferDepth: .empty
        ))

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        guard case .frameAdmitted(_, let ptsUs, _) = event else {
            return XCTFail("Expected only the event emitted after subscription")
        }
        XCTAssertEqual(ptsUs, 10)
    }

    func testPipelineBusObserversCanBeRemoved() {
        let bus = PipelineBus()
        let received = LockedCounter()
        let observation = bus.observe { _ in received.increment() }
        let context = PipelineContext(
            trackId: "audio",
            mediaKind: .audio,
            timestampNanos: 1
        )

        bus.emit(.transportClosed(context: context, error: nil))
        observation.cancel()
        bus.emit(.transportClosed(context: context, error: nil))

        XCTAssertEqual(received.value, 1)
    }

    func testPipelineBusKeepsOnlyNewestEventsForSlowConsumer() async throws {
        let bus = PipelineBus(capacity: 2)
        let stream = bus.events()
        let context = PipelineContext(
            trackId: "video",
            mediaKind: .video,
            timestampNanos: 1
        )

        for ptsUs in 1...3 {
            bus.emit(.decoderInputQueued(context: context, ptsUs: Int64(ptsUs)))
        }

        var iterator = stream.makeAsyncIterator()
        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()
        let first = try XCTUnwrap(firstEvent)
        let second = try XCTUnwrap(secondEvent)
        guard case .decoderInputQueued(_, let firstPts) = first,
              case .decoderInputQueued(_, let secondPts) = second
        else {
            return XCTFail("Expected decoder input events")
        }
        XCTAssertEqual(firstPts, 2)
        XCTAssertEqual(secondPts, 3)
    }

    func testFrameDropLogIncludesDiagnosticReasonAndContext() throws {
        let event = PipelineEvent.frameDropped(
            context: PipelineContext(
                trackId: "video-1080p",
                mediaKind: .video,
                timestampNanos: 42,
                dropDiagnostics: FrameDropDiagnostics(
                    decision: .backlogOverflow(exceededLimits: [.frames, .bytes, .duration]),
                    playheadUs: 1_000_000,
                    bufferDepthBefore: BufferDepth(
                        frames: 12,
                        bytes: 12_288,
                        durationUs: 1_500_000
                    ),
                    bufferDepthAfter: BufferDepth(
                        frames: 9,
                        bytes: 8_192,
                        durationUs: 900_000
                    ),
                    bufferLimits: BufferLimits(
                        maxFrames: 10,
                        maxBytes: 10_000,
                        maxDurationUs: 1_000_000
                    )
                )
            ),
            stage: .buffer,
            reason: .backlogOverflow,
            ptsUs: 1_234,
            groupSequence: 7,
            count: 3,
            bytes: 4_096
        )

        XCTAssertEqual(
            try XCTUnwrap(event.frameDropLogDescription),
            "Frame dropped track=video-1080p, media=video, stage=buffer, "
                + "reason=backlogOverflow, pts=00:00:00.001234, groupSequence=7, "
                + "count=3, bytes=4096, playhead=00:00:01.000000, "
                + "decision=buffer capacity exceeded (frames, bytes, duration), "
                + "bufferBefore=12 frames/12.0 KiB/1.500s, "
                + "bufferAfter=9 frames/8.0 KiB/900ms, "
                + "limits=10 frames/9.8 KiB/1.000s, timestampNanos=42"
        )
        XCTAssertFalse(event.shouldLogFrameDrop)
    }

    func testStaleDropLogExplainsTimestampDifferenceAndTolerance() throws {
        let event = PipelineEvent.frameDropped(
            context: PipelineContext(
                trackId: "audio",
                mediaKind: .audio,
                timestampNanos: 7,
                dropDiagnostics: FrameDropDiagnostics(
                    decision: .staleVsPlayback(
                        reference: .playhead,
                        referenceTimestampUs: 3_000_000,
                        timestampDeltaUs: -1_250_001,
                        toleranceUs: 1_000_000
                    ),
                    playheadUs: 3_000_000,
                    bufferDepthBefore: BufferDepth(
                        frames: 4,
                        bytes: 2_048,
                        durationUs: 120_000
                    ),
                    bufferDepthAfter: BufferDepth(
                        frames: 4,
                        bytes: 2_048,
                        durationUs: 120_000
                    )
                )
            ),
            stage: .timeline,
            reason: .staleVsPlayback,
            ptsUs: 1_749_999
        )

        XCTAssertEqual(
            try XCTUnwrap(event.frameDropLogDescription),
            "Frame dropped track=audio, media=audio, stage=timeline, "
                + "reason=staleVsPlayback, pts=00:00:01.749999, groupSequence=nil, "
                + "count=1, bytes=0, playhead=00:00:03.000000, "
                + "decision=frame is 1.250001s behind playhead (00:00:03.000000); "
                + "allowed lateness=1.000s; "
                + "exceeded by=250.001ms, bufferBefore=4 frames/2.0 KiB/120ms, "
                + "bufferAfter=4 frames/2.0 KiB/120ms, limits=nil, timestampNanos=7"
        )
        XCTAssertFalse(event.shouldLogFrameDrop)
    }

    func testOtherFrameDropReasonsRemainLogged() {
        let event = PipelineEvent.frameDropped(
            context: PipelineContext(
                trackId: "video",
                mediaKind: .video,
                timestampNanos: 1
            ),
            stage: .decoder,
            reason: .invalidPayload
        )

        XCTAssertTrue(event.shouldLogFrameDrop)
    }

    func testNonDropEventHasNoFrameDropLog() {
        let event = PipelineEvent.transportClosed(
            context: PipelineContext(
                trackId: "audio",
                mediaKind: .audio,
                timestampNanos: 1
            ),
            error: nil
        )

        XCTAssertNil(event.frameDropLogDescription)
    }

    func testPolicyDefaultsMatchPlaybackBaseline() {
        XCTAssertEqual(PipelinePolicies.timeline.maxGapUs, 500_000)
        XCTAssertEqual(PipelinePolicies.admission.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(PipelinePolicies.admission.maxFrames, 1_024)
        XCTAssertEqual(PipelinePolicies.render.fallbackLeadUs, 50_000)
        XCTAssertEqual(PipelinePolicies.render.maxLeadUs, 100_000)
        XCTAssertEqual(PipelinePolicies.render.frameIntervalMultiplier, 3)
        XCTAssertEqual(PipelinePolicies.clock.retargetToleranceUs, 20_000)
        XCTAssertEqual(PipelinePolicies.switch.keyframeTimeoutUs, 5_000_000)
    }

    func testBufferDepthRejectsNegativeValues() {
        XCTAssertEqual(BufferDepth.empty.frames, 0)
        XCTAssertEqual(BufferDepth.empty.bytes, 0)
        XCTAssertEqual(BufferDepth.empty.durationUs, 0)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
