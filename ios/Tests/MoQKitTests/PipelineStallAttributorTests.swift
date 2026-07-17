@testable import MoQKit
import XCTest

final class PipelineStallAttributorTests: XCTestCase {
    func testSilentPublisherIsAttributedUpstream() {
        let bus = PipelineBus()
        let attributor = PipelineStallAttributor(bus: bus, policy: StallPolicy(arrivalGapUs: 100))
        let context = PipelineContext(trackId: "video", mediaKind: .video, timestampNanos: 0)
        bus.emit(.frameArrived(
            context: context,
            ptsUs: 0,
            groupSequence: nil,
            frameIndex: nil,
            bytes: 1
        ))

        XCTAssertEqual(
            attributor.cause(
                trackId: "video",
                mediaKind: .video,
                nowNanos: 100_000,
                fallback: .renderStall
            ),
            .publisherIdle
        )
    }

    func testZeroReceiveBandwidthDistinguishesNetworkIdle() {
        let bus = PipelineBus()
        let attributor = PipelineStallAttributor(bus: bus, policy: StallPolicy(arrivalGapUs: 100))
        let context = PipelineContext(trackId: "audio", mediaKind: .audio, timestampNanos: 0)
        bus.emit(.frameArrived(
            context: context,
            ptsUs: 0,
            groupSequence: nil,
            frameIndex: nil,
            bytes: 1
        ))
        bus.emit(.bandwidthSample(
            context: context,
            receiveBitsPerSecond: 0,
            sendBitsPerSecond: nil
        ))

        XCTAssertEqual(
            attributor.cause(
                trackId: "audio",
                mediaKind: .audio,
                nowNanos: 100_000,
                fallback: .renderStall
            ),
            .networkIdle
        )
    }

    func testPreparingRenditionOwnsSwitchStall() {
        let bus = PipelineBus()
        let attributor = PipelineStallAttributor(bus: bus)
        let context = PipelineContext(trackId: "high", mediaKind: .video, timestampNanos: 0)
        bus.emit(.switchProgress(context: context, phase: .preparing))

        XCTAssertEqual(
            attributor.cause(
                trackId: "high",
                mediaKind: .video,
                nowNanos: 0,
                fallback: .renderStall
            ),
            .switchStall
        )
    }
}
