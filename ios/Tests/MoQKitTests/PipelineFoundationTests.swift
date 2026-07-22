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
