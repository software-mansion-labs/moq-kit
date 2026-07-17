@testable import MoQKit
import XCTest

final class FrameBufferTests: XCTestCase {
    func testResetRequiresKeyframeBeforeAdmission() {
        let buffer = FrameBuffer<String>(policy: AdmissionPolicy())
        _ = buffer.reset(epoch: 1)

        let delta = buffer.offer(timedBufferFrame(timestampUs: 1))
        let keyframe = buffer.offer(timedBufferFrame(timestampUs: 2, keyframe: true))

        XCTAssertEqual(delta, [.rejected(reason: .waitingForKeyframe)])
        XCTAssertEqual(keyframe, [.admitted])
        XCTAssertEqual(buffer.depth().frames, 1)
    }

    func testBufferMaintainsDecodeOrder() {
        let buffer = FrameBuffer<String>(
            policy: AdmissionPolicy(requireKeyframeAfterReset: false)
        )

        _ = buffer.offer(timedBufferFrame(timestampUs: 30))
        _ = buffer.offer(timedBufferFrame(timestampUs: 10))
        _ = buffer.offer(timedBufferFrame(timestampUs: 20))

        XCTAssertEqual(buffer.removeFront()?.timestampUs, 10)
        XCTAssertEqual(buffer.removeFront()?.timestampUs, 20)
        XCTAssertEqual(buffer.removeFront()?.timestampUs, 30)
    }

    func testOverflowEvictsWholeOldestGop() {
        let buffer = FrameBuffer<String>(
            policy: AdmissionPolicy(
                maxBytes: 100,
                maxFrames: 3,
                maxDurationUs: 1_000,
                requireKeyframeAfterReset: false
            )
        )

        _ = buffer.offer(timedBufferFrame(timestampUs: 0, keyframe: true))
        _ = buffer.offer(timedBufferFrame(timestampUs: 10))
        _ = buffer.offer(timedBufferFrame(timestampUs: 20))
        let effects = buffer.offer(timedBufferFrame(timestampUs: 30, keyframe: true))

        XCTAssertTrue(effects.contains(.evictedGop(count: 3, bytes: 3)))
        XCTAssertEqual(buffer.peekFront()?.timestampUs, 30)
        XCTAssertEqual(buffer.depth().frames, 1)
    }
}

private func timedBufferFrame(
    timestampUs: Int64,
    keyframe: Bool = false,
    epoch: UInt64 = 1
) -> PipelineFrame<String> {
    PipelineFrame(
        payload: "frame",
        timestampUs: timestampUs,
        keyframe: keyframe,
        sizeBytes: 1,
        epoch: epoch
    )
}
