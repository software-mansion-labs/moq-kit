import CoreMedia
@testable import MoQKit
import XCTest

final class VideoPresentationHorizonTests: XCTestCase {
    func testFutureVisibleHorizonDelaysStallStart() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 100_000)

        XCTAssertFalse(
            horizon.recordVisibleFrame(
                sampleBuffer: sample,
                presentationTime: cmTime(1_000_000),
                frontFrameIntervalUs: nil
            ))

        XCTAssertEqual(horizon.evaluateStallStart(at: 1_050_000), .wait(delayUs: 50_000))
        XCTAssertTrue(horizon.hasPendingStallMarker)
        XCTAssertFalse(horizon.isStalled)
    }

    func testStallStartsWhenVisibleHorizonHasElapsed() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 100_000)

        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil
        )

        XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .beginStall)
        XCTAssertTrue(horizon.isStalled)
        XCTAssertFalse(horizon.hasPendingStallMarker)
    }

    func testSampleDurationIsPreferredOverFrameInterval() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: 100_000
        )

        XCTAssertEqual(horizon.lastVisibleFrameEndUs, 1_040_000)
    }

    func testFrontFrameIntervalIsUsedWhenSampleDurationIsUnavailable() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: nil)

        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: 50_000
        )

        XCTAssertEqual(horizon.lastVisibleFrameEndUs, 1_050_000)
    }

    func testVisiblePTSDeltaIsUsedWhenSampleDurationAndFrontIntervalAreUnavailable() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: nil)

        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil
        )
        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_060_000),
            frontFrameIntervalUs: nil
        )

        XCTAssertEqual(horizon.lastVisibleFrameEndUs, 1_120_000)
    }

    func testNewPlayableFrameClearsActiveStall() throws {
        var horizon = VideoPresentationHorizon()
        let first = try makeSampleBuffer(durationUs: 40_000)
        let second = try makeSampleBuffer(durationUs: 40_000)

        horizon.recordVisibleFrame(
            sampleBuffer: first,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil
        )
        XCTAssertEqual(horizon.evaluateStallStart(at: 1_040_000), .beginStall)

        XCTAssertTrue(
            horizon.recordVisibleFrame(
                sampleBuffer: second,
                presentationTime: cmTime(1_080_000),
                frontFrameIntervalUs: nil
            ))
        XCTAssertFalse(horizon.isStalled)
    }

    func testResetClearsVisibleHorizonAndPendingCheck() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 100_000)

        horizon.recordVisibleFrame(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil
        )
        XCTAssertEqual(horizon.evaluateStallStart(at: 1_050_000), .wait(delayUs: 50_000))

        horizon.reset()

        XCTAssertNil(horizon.lastVisibleFramePTSUs)
        XCTAssertNil(horizon.lastVisibleFrameEndUs)
        XCTAssertFalse(horizon.hasPendingStallMarker)
        XCTAssertFalse(horizon.isStalled)
    }
}

private func cmTime(_ microseconds: UInt64) -> CMTime {
    CMTime(value: CMTimeValue(microseconds), timescale: 1_000_000)
}

private func makeSampleBuffer(durationUs: UInt64?) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
        duration: durationUs.map(cmTime) ?? .invalid,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = 0
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        formatDescription: nil,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw NSError(
            domain: "VideoPresentationHorizonTests",
            code: Int(status),
            userInfo: nil
        )
    }
    return sampleBuffer
}
