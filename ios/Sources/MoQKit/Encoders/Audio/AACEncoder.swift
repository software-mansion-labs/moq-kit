import AudioToolbox
import CoreMedia
import Foundation

/// Hardware AAC encoder using `AudioConverter`.
final class AACEncoder: AudioEncoding {
    private var converter: AudioConverterRef?
    private var inputFormat: AudioStreamBasicDescription?

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

        guard let pcmData = extractPCMData(from: sampleBuffer) else { return [] }

        guard let encoded = encodePacket(pcmData: pcmData, inputASBD: inputASBD) else { return [] }

        return [MoQEncodedAudioFrame(data: encoded, presentationTime: pts)]
    }

    func buildInitData() -> Data {
        buildAudioSpecificConfig()
    }

    func stop() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
    }

    // MARK: - Private

    private func createConverter(inputASBD: AudioStreamBasicDescription) throws {
        self.inputFormat = inputASBD

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

        var inASBD = inputASBD
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&inASBD, &outputASBD, &ref)
        guard status == noErr, let ref else {
            throw MoQSessionError.invalidConfiguration("Failed to create AudioConverter: \(status)")
        }
        self.converter = ref

        var bitrate = config.bitrate
        AudioConverterSetProperty(
            ref, kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size), &bitrate
        )
    }

    private func encodePacket(pcmData: Data, inputASBD: AudioStreamBasicDescription) -> Data? {
        guard let converter else { return nil }

        var inputData = pcmData
        var outputPacketDescription = AudioStreamPacketDescription()
        var ioOutputDataPacketSize: UInt32 = 1

        let maxOutputSize = 8192
        var outputData = Data(count: maxOutputSize)

        var outBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: config.channels,
                mDataByteSize: UInt32(maxOutputSize),
                mData: nil
            )
        )

        let status = outputData.withUnsafeMutableBytes { outputPtr -> OSStatus in
            outBufferList.mBuffers.mData = outputPtr.baseAddress
            outBufferList.mBuffers.mDataByteSize = UInt32(maxOutputSize)

            return inputData.withUnsafeMutableBytes { inputPtr -> OSStatus in
                var userData = AACEncoderUserData(
                    data: inputPtr.baseAddress!,
                    size: UInt32(pcmData.count),
                    consumed: false,
                    inputASBD: inputASBD
                )

                return withUnsafeMutablePointer(to: &userData) { userDataPtr in
                    AudioConverterFillComplexBuffer(
                        converter,
                        aacEncoderInputCallback,
                        userDataPtr,
                        &ioOutputDataPacketSize,
                        &outBufferList,
                        &outputPacketDescription
                    )
                }
            }
        }

        guard status == noErr, ioOutputDataPacketSize > 0 else { return nil }

        let encodedSize = Int(outBufferList.mBuffers.mDataByteSize)
        return outputData.prefix(encodedSize)
    }

    /// Build a 2-byte AudioSpecificConfig for AAC-LC.
    private func buildAudioSpecificConfig() -> Data {
        let objectType: UInt8 = 2  // AAC-LC
        let freqIndex = aacFrequencyIndex(for: config.sampleRate)
        let channelConfig = UInt8(config.channels)

        // AudioSpecificConfig: 5 bits objectType | 4 bits freqIndex | 4 bits channelConfig | 3 bits padding
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

    private func extractPCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard let dataPointer, totalLength > 0 else { return nil }
        return Data(bytes: dataPointer, count: totalLength)
    }
}

// MARK: - AudioConverter Fill Callback

private struct AACEncoderUserData {
    var data: UnsafeMutableRawPointer
    var size: UInt32
    var consumed: Bool
    var inputASBD: AudioStreamBasicDescription
}

private func aacEncoderInputCallback(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<
        UnsafeMutablePointer<AudioStreamPacketDescription>?
    >?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }
    let userData = inUserData.assumingMemoryBound(to: AACEncoderUserData.self)

    if userData.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    ioData.pointee.mBuffers.mData = userData.pointee.data
    ioData.pointee.mBuffers.mDataByteSize = userData.pointee.size
    ioData.pointee.mBuffers.mNumberChannels = userData.pointee.inputASBD.mChannelsPerFrame

    let bytesPerFrame = userData.pointee.inputASBD.mBytesPerFrame
    if bytesPerFrame > 0 {
        ioNumberDataPackets.pointee = userData.pointee.size / UInt32(bytesPerFrame)
    }

    userData.pointee.consumed = true

    return noErr
}
