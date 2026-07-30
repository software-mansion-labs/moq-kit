import CoreMedia
@testable import MoQKit
import XCTest

final class VideoPresentationHorizonTests: XCTestCase {
    func testNoSubmittedHorizonRemainsBuffering() {
        var horizon = VideoPresentationHorizon()

        XCTAssertEqual(horizon.evaluateStallStart(at: 1_000_000), .buffering)
        XCTAssertFalse(horizon.isStalled)
    }

    func testFutureSubmittedHorizonDelaysStallStart() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 100_000)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_000_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_000_000
            ),
            .horizonExtended(endUs: 1_100_000)
        )

        XCTAssertEqual(horizon.evaluateStallStart(at: 1_050_000), .wait(delayUs: 50_000))
        XCTAssertFalse(horizon.isStalled)
    }

    func testStallStartsOnceWhenSubmittedHorizonHasElapsed() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 100_000)

        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil,
            playheadUs: 1_000_000
        )

        XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .beginStall)
        XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .alreadyStalled)
        XCTAssertTrue(horizon.isStalled)
    }

    func testSampleDurationIsPreferredOverFrameInterval() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: 100_000,
            playheadUs: 1_000_000
        )

        XCTAssertEqual(horizon.submittedHorizonEndUs, 1_040_000)
    }

    func testFrontFrameIntervalIsUsedWhenSampleDurationIsUnavailable() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: nil)

        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: 50_000,
            playheadUs: 1_000_000
        )

        XCTAssertEqual(horizon.submittedHorizonEndUs, 1_050_000)
    }

    func testSubmittedPTSDeltaIsUsedWhenExplicitDurationsAreUnavailable() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: nil)

        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil,
            playheadUs: 1_000_000
        )
        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_060_000),
            frontFrameIntervalUs: nil,
            playheadUs: 1_000_000
        )

        XCTAssertEqual(horizon.submittedHorizonEndUs, 1_120_000)
    }

    func testEarlierPTSDoesNotShrinkHorizonOrMoveCadenceAnchorBackward() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: nil)

        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_000_000),
            frontFrameIntervalUs: nil,
            playheadUs: 1_000_000
        )
        horizon.recordSubmittedSample(
            sampleBuffer: sample,
            presentationTime: cmTime(1_060_000),
            frontFrameIntervalUs: nil,
            playheadUs: 1_000_000
        )

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_030_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_000_000
            ),
            .ignored
        )
        XCTAssertEqual(horizon.submittedHorizonEndUs, 1_120_000)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_120_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_000_000
            ),
            .horizonExtended(endUs: 1_180_000)
        )
    }

    func testInvalidPresentationTimeDoesNotExtendHorizon() throws {
        var horizon = VideoPresentationHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: .invalid,
                frontFrameIntervalUs: nil,
                playheadUs: 0
            ),
            .ignored
        )
        XCTAssertNil(horizon.submittedHorizonEndUs)
    }

    func testExpiredSubmissionDoesNotEndActiveStall() throws {
        var horizon = try makeStalledHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_050_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_100_000
            ),
            .horizonExtended(endUs: 1_090_000)
        )
        XCTAssertTrue(horizon.isStalled)
    }

    func testFutureSubmissionEndsActiveStallOnce() throws {
        var horizon = try makeStalledHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_120_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_100_000
            ),
            .stallEnded(endUs: 1_160_000)
        )
        XCTAssertFalse(horizon.isStalled)

        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_120_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_100_000
            ),
            .ignored
        )
    }

    func testCoverageResetPreservesActiveStallUntilFutureSubmission() throws {
        var horizon = try makeStalledHorizon()
        let sample = try makeSampleBuffer(durationUs: 40_000)

        horizon.resetCoverage()

        XCTAssertNil(horizon.submittedHorizonEndUs)
        XCTAssertTrue(horizon.isStalled)
        XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .alreadyStalled)
        XCTAssertEqual(
            horizon.recordSubmittedSample(
                sampleBuffer: sample,
                presentationTime: cmTime(1_120_000),
                frontFrameIntervalUs: nil,
                playheadUs: 1_100_000
            ),
            .stallEnded(endUs: 1_160_000)
        )
    }

    func testFullResetClearsCoverageAndStall() throws {
        var horizon = try makeStalledHorizon()

        horizon.reset()

        XCTAssertNil(horizon.submittedHorizonEndUs)
        XCTAssertFalse(horizon.isStalled)
        XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .buffering)
    }

    func testWallDelayAccountsForMaximumClockRate() {
        XCTAssertEqual(
            VideoPresentationHorizon.conservativeWallDelayUs(
                mediaDelayUs: 100_000,
                maxClockRate: 0.95
            ),
            100_000
        )
        XCTAssertEqual(
            VideoPresentationHorizon.conservativeWallDelayUs(
                mediaDelayUs: 100_000,
                maxClockRate: 1.0
            ),
            100_000
        )
        XCTAssertEqual(
            VideoPresentationHorizon.conservativeWallDelayUs(
                mediaDelayUs: 100_000,
                maxClockRate: 1.05
            ),
            95_238
        )
    }

    func testWallDelayHandlesZeroAndInvalidClockRates() {
        XCTAssertEqual(
            VideoPresentationHorizon.conservativeWallDelayUs(
                mediaDelayUs: 0,
                maxClockRate: 1.05
            ),
            0
        )
        XCTAssertEqual(
            VideoPresentationHorizon.conservativeWallDelayUs(
                mediaDelayUs: 100_000,
                maxClockRate: .nan
            ),
            100_000
        )
    }
}

private func makeStalledHorizon() throws -> VideoPresentationHorizon {
    var horizon = VideoPresentationHorizon()
    let sample = try makeSampleBuffer(durationUs: 40_000)
    horizon.recordSubmittedSample(
        sampleBuffer: sample,
        presentationTime: cmTime(1_000_000),
        frontFrameIntervalUs: nil,
        playheadUs: 1_000_000
    )
    XCTAssertEqual(horizon.evaluateStallStart(at: 1_100_000), .beginStall)
    return horizon
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
