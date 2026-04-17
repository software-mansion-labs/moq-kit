import AVFoundation
import CoreMedia
import Foundation

/// AAC encoder using `AVAudioConverter`.
final class AACEncoder: AudioEncoding {
    private var converter: AVAudioConverter?
    private var resamplingConverter: AVAudioConverter?

    let config: MoQAudioEncoderConfig

    init(config: MoQAudioEncoderConfig) {
        self.config = config
    }

    func encode(_ sampleBuffer: CMSampleBuffer) -> [MoQEncodedAudioFrame] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return [] }

        let inputASBD = asbdPtr.pointee
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if converter == nil {
            do {
                try createConverter(inputASBD: inputASBD)
            } catch {
                MoQLogger.publish.error("Failed to create AAC audio converter: \(error)")
                return []
            }
        }

        guard let converter else { return [] }
        guard let pcmBuffer = asPCMBuffer(sampleBuffer, targetFormat: converter.inputFormat) else {
            return []
        }

        var frames: [MoQEncodedAudioFrame] = []
        var fed = false
        let outputSamplesPerPacket = Int64(
            converter.outputFormat.streamDescription.pointee.mFramesPerPacket
        )
        let maximumPacketSize = max(converter.maximumOutputPacketSize, 4096)
        var packetsDrained: Int64 = 0

        while true {
            let outputBuffer = AVAudioCompressedBuffer(
                format: converter.outputFormat,
                packetCapacity: 1,
                maximumPacketSize: maximumPacketSize
            )

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

            if status == .error {
                let message = error?.localizedDescription ?? "unknown"
                MoQLogger.publish.error("AAC conversion failed: \(message)")
                break
            }

            guard outputBuffer.byteLength > 0, outputBuffer.packetCount > 0 else { break }

            let offsetSeconds = Double(packetsDrained * outputSamplesPerPacket) / config.sampleRate
            let currentPTS = CMTimeAdd(pts, CMTime(seconds: offsetSeconds, preferredTimescale: pts.timescale))
            packetsDrained += 1

            frames.append(
                MoQEncodedAudioFrame(
                    data: Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength)),
                    presentationTime: currentPTS
                )
            )
        }

        return frames
    }

    func buildInitData() -> Data {
        buildAudioSpecificConfig()
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
                interleaved: false
            )
        else {
            throw MoQSessionError.invalidConfiguration("Failed to create input AVAudioFormat")
        }

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: config.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        guard let outputAVFormat = AVAudioFormat(streamDescription: &outputASBD) else {
            throw MoQSessionError.invalidConfiguration("Failed to create AAC output AVAudioFormat")
        }

        guard let converter = AVAudioConverter(from: inputAVFormat, to: outputAVFormat) else {
            throw MoQSessionError.invalidConfiguration("Failed to create AVAudioConverter for AAC")
        }

        converter.bitRate = Int(config.bitrate)
        self.converter = converter
    }

    /// Build a 2-byte AudioSpecificConfig for AAC-LC.
    private func buildAudioSpecificConfig() -> Data {
        let objectType: UInt8 = 2  // AAC-LC
        let freqIndex = aacFrequencyIndex(for: config.sampleRate)
        let channelConfig = UInt8(config.channels)

        let byte0 = (objectType << 3) | (freqIndex >> 1)
        let byte1 = ((freqIndex & 0x01) << 7) | (channelConfig << 3)
        return Data([byte0, byte1])
    }

    private func aacFrequencyIndex(for sampleRate: Double) -> UInt8 {
        let table: [(Double, UInt8)] = [
            (96000, 0), (88200, 1), (64000, 2), (48000, 3),
            (44100, 4), (32000, 5), (24000, 6), (22050, 7),
            (16000, 8), (12000, 9), (11025, 10), (8000, 11),
            (7350, 12),
        ]
        let roundedRate = round(sampleRate)
        for (freq, index) in table {
            if abs(roundedRate - freq) < 1.0 { return index }
        }
        return 15
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
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else { return nil }

        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        if sourceFormat == targetFormat { return sourceBuffer }

        if resamplingConverter == nil {
            resamplingConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let formatConverter = resamplingConverter else { return nil }

        let targetFrameCount = AVAudioFrameCount(
            ceil(Double(frameCount) * targetFormat.sampleRate / sourceFormat.sampleRate) * 2
        )
        guard
            let targetBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: targetFrameCount
            )
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
