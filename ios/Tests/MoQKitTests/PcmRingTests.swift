@testable import MoQKit
import XCTest

final class PcmRingTests: XCTestCase {
    func testWriteReportsInsertedSilenceForTimestampGap() {
        var ring = PcmRing(
            rate: 1_000,
            channels: 1,
            policy: PcmRingPolicy(maxFrames: 10, maxDurationUs: 10_000)
        )

        _ = write([1, 2], timestampUs: 0, to: &ring)
        let result = write([3, 4], timestampUs: 4_000, to: &ring)

        XCTAssertEqual(result.acceptedFrames, 2)
        XCTAssertEqual(result.silenceFrames, 2)
        XCTAssertNil(result.diagnostics)
        XCTAssertEqual(ring.length, 6)
    }

    func testOverflowReportsEvictedFramesAndKeepsBound() {
        var ring = PcmRing(
            rate: 1_000,
            channels: 1,
            policy: PcmRingPolicy(maxFrames: 4, maxDurationUs: 10_000)
        )

        let result = write([1, 2, 3, 4, 5], timestampUs: 0, to: &ring)

        XCTAssertEqual(result.acceptedFrames, 5)
        XCTAssertEqual(result.evictedFrames, 1)
        XCTAssertEqual(result.diagnostics?.depthBefore.frames, 0)
        XCTAssertEqual(result.diagnostics?.peakDepth.frames, 5)
        XCTAssertEqual(result.diagnostics?.depthAfter.frames, 4)
        XCTAssertEqual(result.diagnostics?.playheadUs, 0)
        XCTAssertEqual(result.diagnostics?.bufferLimits.maxFrames, 4)
        XCTAssertEqual(
            result.diagnostics?.peakDepth.exceededLimits(of: result.diagnostics?.bufferLimits),
            [.frames]
        )
        XCTAssertEqual(ring.length, 4)
    }

    func testOldWriteReportsPlayheadAndTimestampDelta() {
        var ring = PcmRing(
            rate: 1_000,
            channels: 1,
            policy: PcmRingPolicy(maxFrames: 4, maxDurationUs: 10_000)
        )
        _ = write([1, 2, 3, 4], timestampUs: 0, to: &ring)
        var output = [[Float32](repeating: 0, count: 3)]
        _ = ring.read(into: &output, frameCount: 3)

        let result = write([5, 6], timestampUs: 0, to: &ring)

        XCTAssertEqual(result.rejectedOldFrames, 2)
        XCTAssertEqual(result.diagnostics?.playheadUs, 3_000)
        XCTAssertEqual(result.diagnostics?.timestampDeltaUs, -3_000)
        XCTAssertEqual(result.diagnostics?.depthBefore.frames, 1)
        XCTAssertEqual(result.diagnostics?.depthAfter.frames, 1)
    }

    func testFullRingCanBeReadWithoutInterleaving() {
        var ring = PcmRing(
            rate: 1_000,
            channels: 1,
            policy: PcmRingPolicy(maxFrames: 4, maxDurationUs: 10_000)
        )
        _ = write([1, 2, 3, 4], timestampUs: 0, to: &ring)
        var output = [[Float32](repeating: 0, count: 4)]

        let count = ring.read(into: &output, frameCount: 4)

        XCTAssertEqual(count, 4)
        XCTAssertEqual(output[0], [1, 2, 3, 4])
    }
}

private func write(
    _ samples: [Float32],
    timestampUs: UInt64,
    to ring: inout PcmRing
) -> PcmWriteResult {
    var mutable = samples
    return mutable.withUnsafeMutableBufferPointer { channel in
        let pointers = [channel.baseAddress!]
        return pointers.withUnsafeBufferPointer { channels in
            ring.write(
                timestampUs: timestampUs,
                channelData: channels.baseAddress!,
                frameCount: samples.count
            )
        }
    }
}
