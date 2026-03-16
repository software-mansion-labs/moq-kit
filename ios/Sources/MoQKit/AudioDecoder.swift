import AVFoundation

// MARK: - AudioDecoder

/// Decodes compressed audio (AAC/Opus) to PCM Float32 interleaved using `AVAudioConverter`.
final class AudioDecoder: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    let framesPerPacket: AVAudioFrameCount

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat

    init(config: MoqAudio) throws {
        let codec = config.codec.lowercased()

        let formatID: AudioFormatID
        let fpp: AVAudioFrameCount
        if codec.hasPrefix("mp4a") || codec == "aac" {
            formatID = kAudioFormatMPEG4AAC
            fpp = 1024
        } else if codec == "opus" {
            formatID = kAudioFormatOpus
            fpp = 960
        } else {
            throw MoQSessionError.unsupportedCodec(config.codec)
        }
        self.framesPerPacket = fpp

        // Build input AudioStreamBasicDescription
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(fpp),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        guard let inFmt = AVAudioFormat(streamDescription: &asbd) else {
            throw MoQSessionError.audioDecoderFailed("Failed to create input AVAudioFormat")
        }

        // Apply magic cookie if present
        if let descData = config.description, !descData.isEmpty {
            inFmt.magicCookie = descData
        }

        self.inputFormat = inFmt

        // Output: PCM Float32 non-interleaved (required by AVAudioEngine's mainMixerNode)
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Float64(config.sampleRate),
            channels: AVAudioChannelCount(config.channelCount),
            interleaved: false
        ) else {
            throw MoQSessionError.audioDecoderFailed("Failed to create output AVAudioFormat")
        }
        self.outputFormat = outFmt

        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw MoQSessionError.audioDecoderFailed(
                "Failed to create AVAudioConverter from \(inFmt) to \(outFmt)")
        }
        self.converter = conv
    }

    /// Decode a single compressed audio packet to PCM.
    func decode(payload: Data) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: framesPerPacket
        ) else {
            throw MoQSessionError.audioDecoderFailed("Failed to allocate output PCM buffer")
        }

        // Wrap payload in a compressed buffer
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: payload.count
        )
        payload.withUnsafeBytes { rawBuf in
            let src = rawBuf.bindMemory(to: UInt8.self)
            compressedBuffer.data.copyMemory(from: src.baseAddress!, byteCount: src.count)
            compressedBuffer.byteLength = UInt32(src.count)
            compressedBuffer.packetCount = 1
            compressedBuffer.packetDescriptions!.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(src.count)
            )
        }

        var conversionError: NSError?
        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        if status == .error {
            let msg = conversionError?.localizedDescription ?? "unknown"
            throw MoQSessionError.audioDecoderFailed("AVAudioConverter failed: \(msg)")
        }

        return outputBuffer
    }
}
