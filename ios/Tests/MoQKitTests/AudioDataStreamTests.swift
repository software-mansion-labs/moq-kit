import AVFoundation
import Foundation
@testable import MoQKit
import XCTest

final class AudioDataStreamTests: XCTestCase {
    func testAudioStreamBuffersNewestDecodedChunks() async throws {
        let (stream, continuation) = AudioDataStream.makeBufferedAudioStream()

        for timestampUs in 0..<5 {
            continuation.yield(makeAudioData(timestampUs: UInt64(timestampUs)))
        }
        continuation.finish()

        var timestamps: [UInt64] = []
        for try await audio in stream {
            timestamps.append(audio.timestampUs)
        }

        XCTAssertEqual(timestamps, [2, 3, 4])
    }
}

final class AudioDataConverterTests: XCTestCase {
    func testFloat32OutputIsInterleavedWithMetadata() throws {
        let input = try makeStereoPCMBuffer()
        let converter = try AudioDataConverter(
            sourceFormat: input.format,
            requestedFormat: AudioDataFormat()
        )

        let output = try converter.convert(input, timestampUs: 123_456)

        XCTAssertEqual(output.timestampUs, 123_456)
        XCTAssertEqual(output.sampleRate, 48_000)
        XCTAssertEqual(output.channelCount, 2)
        XCTAssertEqual(output.sampleFormat, .float32)
        XCTAssertEqual(output.frameCount, 3)
        XCTAssertEqual(output.bytes.count, 3 * 2 * MemoryLayout<Float32>.size)

        assertFloat32Samples(
            float32Samples(from: output.bytes),
            equal: [0, 1, 0.5, -0.5, -1, 0.25]
        )
    }

    func testInt16OutputIsClampedAndInterleaved() throws {
        let input = try makeStereoPCMBuffer()
        let converter = try AudioDataConverter(
            sourceFormat: input.format,
            requestedFormat: AudioDataFormat(sampleFormat: .int16)
        )

        let output = try converter.convert(input, timestampUs: 0)

        XCTAssertEqual(output.sampleFormat, .int16)
        XCTAssertEqual(output.bytes.count, 3 * 2 * MemoryLayout<Int16>.size)
        XCTAssertEqual(
            int16Samples(from: output.bytes),
            [0, 32_767, 16_384, -16_384, -32_768, 8_192]
        )
    }

    func testInvalidRequestedFormatThrows() throws {
        let input = try makeStereoPCMBuffer()

        XCTAssertThrowsError(
            try AudioDataConverter(
                sourceFormat: input.format,
                requestedFormat: AudioDataFormat(sampleRate: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionError,
                .invalidConfiguration("Audio data sample rate must be greater than zero")
            )
        }

        XCTAssertThrowsError(
            try AudioDataConverter(
                sourceFormat: input.format,
                requestedFormat: AudioDataFormat(channelCount: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionError,
                .invalidConfiguration("Audio data channel count must be greater than zero")
            )
        }
    }
}

private func makeAudioData(timestampUs: UInt64) -> AudioData {
    AudioData(
        bytes: Data(repeating: 0, count: MemoryLayout<Float32>.size),
        timestampUs: timestampUs,
        sampleRate: 48_000,
        channelCount: 1,
        sampleFormat: .float32,
        frameCount: 1
    )
}

private func makeStereoPCMBuffer() throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
    )
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)
    )
    buffer.frameLength = 3

    let channels = try XCTUnwrap(buffer.floatChannelData)
    channels[0][0] = 0
    channels[0][1] = 0.5
    channels[0][2] = -1
    channels[1][0] = 1
    channels[1][1] = -0.5
    channels[1][2] = 0.25

    return buffer
}

private func float32Samples(from data: Data) -> [Float32] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: MemoryLayout<Float32>.size).map { offset in
        let bits = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float32(bitPattern: bits)
    }
}

private func int16Samples(from data: Data) -> [Int16] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: MemoryLayout<Int16>.size).map { offset in
        let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return Int16(bitPattern: bits)
    }
}

private func assertFloat32Samples(
    _ actual: [Float32],
    equal expected: [Float32],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (actualSample, expectedSample) in zip(actual, expected) {
        XCTAssertEqual(
            Double(actualSample),
            Double(expectedSample),
            accuracy: 0.000_01,
            file: file,
            line: line
        )
    }
}
