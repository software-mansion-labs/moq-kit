import AVFoundation
import Moq
@testable import MoQKit
import XCTest

final class MicrophoneCaptureTests: XCTestCase {
    func testPublisherWaitsForCaptureAndRepublishesAudioAfterRestart() async throws {
        let broadcast = try Moq.BroadcastProducer()
        let catalog = try await broadcast.consume().subscribeCatalog()
        defer { catalog.cancel(); try? broadcast.finish() }
        let publisher = try Publisher()
        let microphone = MicrophoneCapture()
        let track = try publisher.addAudioTrack(source: microphone)
        try publisher.attachBroadcast(broadcast)
        try await publisher.start()
        defer { PublishControl.sync { publisher.stopOwned() } }
        XCTAssertEqual(track.currentState, .idle)
        XCTAssertNil(microphone.onFrame)

        // Drive the same lifecycle and PCM callbacks as AVFoundation, without device hardware.
        await PublishControl.finish { microphone.captureLifecycle.setRunning(true) }
        XCTAssertEqual(track.currentState, .starting)
        let firstInput = try makeSamples(frames: 4800)
        _ = microphone.onFrame?(firstInput)
        let first = try await nextCatalog(catalog)
        XCTAssertEqual(first.audio.count, 1)
        await PublishControl.finish {}
        XCTAssertEqual(track.currentState, .active)
        let oldCallback = microphone.onFrame

        await PublishControl.finish { microphone.captureLifecycle.setRunning(false) }
        XCTAssertEqual(track.currentState, .idle)
        XCTAssertNil(microphone.onFrame)
        let removed = try await nextCatalog(catalog)
        XCTAssertTrue(removed.audio.isEmpty)

        await PublishControl.finish { microphone.captureLifecycle.setRunning(true) }
        XCTAssertEqual(oldCallback?(firstInput), false) // The old run cannot publish again.
        XCTAssertEqual(track.currentState, .starting)
        _ = microphone.onFrame?(try makeSamples(frames: 4800, timestamp: 96_000))
        let resumed = try await nextCatalog(catalog)
        XCTAssertEqual(resumed.audio.count, 1)
        await PublishControl.finish {}
        XCTAssertEqual(track.currentState, .active)
        XCTAssertNotEqual(Set(first.audio.keys), Set(resumed.audio.keys))

        try await track.setEnabled(false)
        XCTAssertEqual(track.currentState, .disabled)
        XCTAssertTrue(microphone.isCapturing)
        let disabled = try await nextCatalog(catalog)
        XCTAssertTrue(disabled.audio.isEmpty)
        try await track.setEnabled(true)
        _ = microphone.onFrame?(try makeSamples(frames: 4800, timestamp: 144_000))
        let reenabled = try await nextCatalog(catalog)
        XCTAssertEqual(reenabled.audio.count, 1)
        XCTAssertNotEqual(Set(resumed.audio.keys), Set(reenabled.audio.keys))
        await track.stop()
        XCTAssertNotNil(publisher.broadcast) // Last media removal does not end the broadcast.
        XCTAssertEqual(track.currentState, .stopped)
        let ended = try await nextCatalog(catalog)
        XCTAssertTrue(ended.audio.isEmpty)
        await PublishControl.finish { microphone.captureLifecycle.setRunning(false) }
        await PublishControl.finish { microphone.captureLifecycle.setRunning(true) }
        XCTAssertNil(microphone.onFrame)
        XCTAssertEqual(track.currentState, .stopped)
    }

    func testStoppedSourcesCanBeAttachedBeforeTheyAreStarted() async throws {
        let publisher = try Publisher()
        let broadcast = try Moq.BroadcastProducer()
        try publisher.attachBroadcast(broadcast)
        let camera = CameraCapture()
        let microphone = MicrophoneCapture()
        let video = try publisher.addVideoTrack(source: camera)
        let audio = try publisher.addAudioTrack(source: microphone)
        try await publisher.start()
        XCTAssertEqual(video.currentState, .idle)
        XCTAssertEqual(audio.currentState, .idle)
        await publisher.stop()
        await PublishControl.finish { camera.captureLifecycle.setRunning(true) }
        await PublishControl.finish { microphone.captureLifecycle.setRunning(true) }
        XCTAssertNil(camera.onFrame)
        XCTAssertNil(microphone.onFrame)
        XCTAssertEqual(video.currentState, .stopped)
        XCTAssertEqual(audio.currentState, .stopped)
    }

    func testMutePreservesTimingFormatAndOriginalPCM() throws {
        for planar in [false, true] {
            let input = try makeSamples(planar: planar)
            let muted = try XCTUnwrap(MicrophoneCapture.silenced(input))
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(input), CMSampleBufferGetPresentationTimeStamp(muted))
            XCTAssertEqual(CMSampleBufferGetNumSamples(input), CMSampleBufferGetNumSamples(muted))
            XCTAssertEqual(CMSampleBufferGetFormatDescription(input), CMSampleBufferGetFormatDescription(muted))
            let original = try XCTUnwrap(CMSampleBufferGetDataBuffer(input))
            let silence = try XCTUnwrap(CMSampleBufferGetDataBuffer(muted))
            let count = CMBlockBufferGetDataLength(original)
            var bytes = [UInt8](repeating: 255, count: count)
            XCTAssertEqual(CMBlockBufferCopyDataBytes(silence, atOffset: 0, dataLength: count, destination: &bytes), noErr)
            XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
            XCTAssertEqual(CMBlockBufferCopyDataBytes(original, atOffset: 0, dataLength: count, destination: &bytes), noErr)
            XCTAssertTrue(bytes.allSatisfy { $0 == 42 })
        }
    }

    func testDisabledTrackRetainsReservationUntilTerminalStop() async throws {
        let camera = CameraCapture()
        let publisher = try Publisher()
        let track = try publisher.addVideoTrack(source: camera, enabled: false)
        XCTAssertFalse(track.isEnabled)
        XCTAssertThrowsError(try publisher.addVideoTrack(name: "duplicate", source: camera))
        try await track.setEnabled(true)
        XCTAssertFalse(camera.isCapturing)
        XCTAssertEqual(track.currentState, .idle)
        await track.stop()
        _ = try publisher.addVideoTrack(name: "replacement", source: camera)
        await publisher.stop()
        await camera.close()
        do { try await camera.start(); XCTFail("Closed capture restarted") } catch {}
    }

    private func nextCatalog(_ consumer: Moq.CatalogConsumer) async throws -> Moq.Catalog {
        let timeout = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            consumer.cancel()
        }
        defer { timeout.cancel() }
        let next = try await consumer.next()
        return try XCTUnwrap(next)
    }

    private func makeSamples(planar: Bool = false, frames: Int = 4, timestamp: Int64 = 48_000) throws -> CMSampleBuffer {
        let bytesPerFrame: UInt32 = 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: planar
                ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
                : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: 2,
            mBitsPerChannel: planar ? 32 : 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        let length = frames * (planar ? 8 : 4)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 42, blockBuffer: data, offsetIntoDestination: 0, dataLength: length), noErr)
        var samples: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(format), sampleCount: frames,
            presentationTimeStamp: CMTime(value: timestamp, timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &samples), noErr)
        return try XCTUnwrap(samples)
    }

}
