import AVFoundation
import CoreMedia
import Foundation

/// Opus encoder using `AVAudioConverter`.
final class OpusEncoder: AudioEncoding {
    private var converter: AVAudioConverter?
    private var resamplingConverter: AVAudioConverter?

    let config: AudioEncoderConfig

    init(config: AudioEncoderConfig) {
        self.config = config
    }

    func encode(_ sampleBuffer: CMSampleBuffer) -> [EncodedAudioFrame] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return [] }

        let inputASBD = asbdPtr.pointee
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if converter == nil {
            do {
                try createConverter(inputASBD: inputASBD)
            } catch {
                KitLogger.publish.error("Failed to create Opus audio converter: \(error)")
                return []
            }
        }

        guard let converter else { return [] }
        guard let pcmBuffer = asPCMBuffer(sampleBuffer, targetFormat: converter.inputFormat) else {
            return []
        }

        // Drain all available packets — the converter's internal buffer may hold
        // leftover frames from previous calls, so one input buffer can yield
        // more than one Opus packet.
        var frames: [EncodedAudioFrame] = []
        var fed = false
        let outputSamplesPerPacket = Int64(converter.outputFormat.streamDescription.pointee.mFramesPerPacket)
        var packetsDrained: Int64 = 0

        while true {
            guard
                let outputBuffer = AVAudioCompressedBuffer(
                    format: converter.outputFormat,
                    packetCapacity: 1,
                    maximumPacketSize: 4096
                ) as AVAudioBuffer? as? AVAudioCompressedBuffer
            else { break }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return pcmBuffer
            }

            guard status != .error, outputBuffer.byteLength > 0 else { break }

            let offsetSeconds = Double(packetsDrained * outputSamplesPerPacket) / config.sampleRate
            let currentPTS = CMTimeAdd(pts, CMTime(seconds: offsetSeconds, preferredTimescale: pts.timescale))
            packetsDrained += 1

            frames.append(EncodedAudioFrame(
                data: Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength)),
                presentationTime: currentPTS
            ))
        }

        return frames
    }

    func buildInitData() -> Data {
        buildOpusHead()
    }

    func stop() {
        converter = nil
        resamplingConverter = nil
    }

    // MARK: - Private

    private func createConverter(inputASBD: AudioStreamBasicDescription) throws {
        guard
            let inputAVFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: config.sampleRate,
                channels: AVAudioChannelCount(config.channels),
                interleaved: false  // We'll provide non-interleaved data to Opus
            )
        else {
            throw SessionError.invalidConfiguration("Failed to create input AVAudioFormat")
        }

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(config.sampleRate * 0.020),  // 20ms frames
            mBytesPerFrame: 0,
            mChannelsPerFrame: config.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        guard let outputAVFormat = AVAudioFormat(streamDescription: &outputASBD) else {
            throw SessionError.invalidConfiguration("Failed to create Opus output AVAudioFormat")
        }

        guard let converter = AVAudioConverter(from: inputAVFormat, to: outputAVFormat) else {
            throw SessionError.invalidConfiguration("Failed to create AVAudioConverter for Opus")
        }

        converter.bitRate = Int(config.bitrate)
        self.converter = converter
    }

    /// Build an OpusHead identification header (RFC 7845 §5.1).
    private func buildOpusHead() -> Data {
        var head = Data()
        head.append(contentsOf: [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64])  // "OpusHead"
        head.append(1)  // version
        head.append(UInt8(config.channels))

        var preSkip: UInt16 = 3840  // standard encoder delay at 48kHz
        withUnsafeBytes(of: &preSkip) { head.append(contentsOf: $0) }

        var sampleRate = UInt32(config.sampleRate)
        withUnsafeBytes(of: &sampleRate) { head.append(contentsOf: $0) }

        var outputGain: Int16 = 0
        withUnsafeBytes(of: &outputGain) { head.append(contentsOf: $0) }

        head.append(0)  // channel mapping family 0
        return head
    }

    private func asPCMBuffer(
        _ sampleBuffer: CMSampleBuffer, targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let sourceFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        // Return directly if formats already match
        if sourceFormat == targetFormat { return sourceBuffer }

        // Reuse the resampling converter so SRC filter state (phase, history)
        // carries across buffer boundaries — recreating it each call produces
        // discontinuities at ~43 Hz.
        if resamplingConverter == nil {
            resamplingConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let formatConverter = resamplingConverter else { return nil }

        let targetFrameCount = AVAudioFrameCount(
            ceil(Double(frameCount) * targetFormat.sampleRate / sourceFormat.sampleRate) * 2
        )
        guard
            let targetBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: targetFrameCount)
        else { return nil }

        var error: NSError?
        var consumed = false
        formatConverter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        return error == nil ? targetBuffer : nil
    }
}
