import AVFoundation
import CoreMedia

// MARK: - MoQSessionError (codec/format related)

public enum MoQSessionError: Error, Sendable {
    case unsupportedCodec(String)
    case missingCodecDescription
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case alreadyPlaying
    case alreadyClosed
    case noTracksAvailable
    case noBroadcastAvailable
    case noTracksSelected
    case connectionFailed(MoQError)
}

// MARK: - SampleBufferFactory

enum SampleBufferFactory {

    // MARK: - Video Format Descriptions

    static func makeVideoFormatDescription(from config: VideoConfig) throws -> CMFormatDescription {
        guard let descData = config.codecDescription else {
            throw MoQSessionError.missingCodecDescription
        }

        let codec = config.codec.lowercased()
        if codec.hasPrefix("avc") {
            return try makeH264FormatDescription(avccData: descData)
        } else if codec.hasPrefix("hev") || codec.hasPrefix("hvc") {
            return try makeHEVCFormatDescription(hvccData: descData)
        } else {
            throw MoQSessionError.unsupportedCodec(config.codec)
        }
    }

    /// Parse AVCC record → extract SPS + PPS → `CMVideoFormatDescriptionCreateFromH264ParameterSets`
    private static func makeH264FormatDescription(avccData: Data) throws -> CMFormatDescription {
        let parameterSets = try parseAVCCParameterSets(avccData)
        return try parameterSets.withUnsafeBufferPointers { pointers, sizes in
            var formatDescription: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescription
            )
            guard status == noErr, let fd = formatDescription else {
                throw MoQSessionError.formatDescriptionFailed(status)
            }
            return fd
        }
    }

    /// Parse HVCC record → extract VPS + SPS + PPS → `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
    private static func makeHEVCFormatDescription(hvccData: Data) throws -> CMFormatDescription {
        let parameterSets = try parseHVCCParameterSets(hvccData)
        return try parameterSets.withUnsafeBufferPointers { pointers, sizes in
            var formatDescription: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            guard status == noErr, let fd = formatDescription else {
                throw MoQSessionError.formatDescriptionFailed(status)
            }
            return fd
        }
    }

    // MARK: - Audio Format Descriptions

    static func makeAudioFormatDescription(from config: AudioConfig) throws -> CMFormatDescription {
        let codec = config.codec.lowercased()

        let formatID: AudioFormatID
        if codec.hasPrefix("mp4a") || codec == "aac" {
            formatID = kAudioFormatMPEG4AAC
        } else if codec == "opus" {
            formatID = kAudioFormatOpus
        } else {
            throw MoQSessionError.unsupportedCodec(config.codec)
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: formatID == kAudioFormatMPEG4AAC ? 1024 : 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var formatDescription: CMFormatDescription?

        if let descData = config.codecDescription, !descData.isEmpty {
            let status = descData.withUnsafeBytes { rawBuf -> OSStatus in
                let buf = rawBuf.bindMemory(to: UInt8.self)
                return CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: buf.count,
                    magicCookie: buf.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }
            guard status == noErr, let fd = formatDescription else {
                throw MoQSessionError.formatDescriptionFailed(status)
            }
            return fd
        } else {
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            guard status == noErr, let fd = formatDescription else {
                throw MoQSessionError.formatDescriptionFailed(status)
            }
            return fd
        }
    }

    // MARK: - Frame → CMSampleBuffer

    static func makeSampleBuffer(
        from frame: MoQFrame,
        formatDescription: CMFormatDescription,
        baseTimestampUs: UInt64
    ) throws -> CMSampleBuffer {
        let payload = frame.payload

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else {
            throw MoQSessionError.sampleBufferFailed(status)
        }

        // Copy frame payload into block buffer
        status = payload.withUnsafeBytes { rawBuf -> OSStatus in
            let buf = rawBuf.bindMemory(to: UInt8.self)
            return CMBlockBufferReplaceDataBytes(
                with: buf.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == noErr else {
            throw MoQSessionError.sampleBufferFailed(status)
        }

        // Build timing
        let relativeUs = frame.timestampUs >= baseTimestampUs
            ? frame.timestampUs - baseTimestampUs
            : 0
        let pts = CMTime(value: CMTimeValue(relativeUs), timescale: 1_000_000)
        
        var duration = CMTime.invalid
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        if mediaType == kCMMediaType_Audio {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                let framesPerPacket = asbd.mFramesPerPacket
                let sampleRate = asbd.mSampleRate
                if framesPerPacket > 0 && sampleRate > 0 {
                    duration = CMTime(value: CMTimeValue(framesPerPacket), timescale: CMTimeScale(sampleRate))
                }
            }
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else {
            throw MoQSessionError.sampleBufferFailed(status)
        }

        return sb
    }
}

// MARK: - AVCC / HVCC Parsing

/// Collection of NAL parameter set data for building format descriptions.
private struct ParameterSetCollection {
    let sets: [Data]

    /// Call the body with arrays of pointers and sizes suitable for CMVideoFormatDescription APIs.
    func withUnsafeBufferPointers<R>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) throws -> R
    ) rethrows -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []

        // We need all Data objects to stay alive while we use their pointers.
        // Use withUnsafeBytes in a nested manner by collecting into contiguous arrays first.
        let contiguous = sets.map { Array($0) }
        for arr in contiguous {
            arr.withUnsafeBufferPointer { buf in
                pointers.append(buf.baseAddress!)
                sizes.append(buf.count)
            }
        }

        return try pointers.withUnsafeBufferPointer { ptrBuf in
            try sizes.withUnsafeBufferPointer { sizeBuf in
                try body(ptrBuf, sizeBuf)
            }
        }
    }
}

/// Parse an AVCC (AVC Decoder Configuration Record) into SPS + PPS parameter sets.
///
/// AVCC layout (ISO 14496-15):
/// ```
/// byte 0:    configurationVersion (1)
/// byte 1:    AVCProfileIndication
/// byte 2:    profile_compatibility
/// byte 3:    AVCLevelIndication
/// byte 4:    lengthSizeMinusOne (lower 2 bits) | 0b111111xx
/// byte 5:    numOfSequenceParameterSets (lower 5 bits) | 0b111xxxxx
/// for each SPS: 2-byte length (big-endian) + SPS data
/// byte N:    numOfPictureParameterSets
/// for each PPS: 2-byte length (big-endian) + PPS data
/// ```
private func parseAVCCParameterSets(_ data: Data) throws -> ParameterSetCollection {
    guard data.count >= 7 else {
        throw MoQSessionError.missingCodecDescription
    }

    var offset = 5
    var parameterSets: [Data] = []

    // SPS
    let numSPS = Int(data[offset]) & 0x1F
    offset += 1
    for _ in 0..<numSPS {
        guard offset + 2 <= data.count else { throw MoQSessionError.missingCodecDescription }
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        guard offset + length <= data.count else { throw MoQSessionError.missingCodecDescription }
        parameterSets.append(data.subdata(in: offset..<(offset + length)))
        offset += length
    }

    // PPS
    guard offset + 1 <= data.count else { throw MoQSessionError.missingCodecDescription }
    let numPPS = Int(data[offset])
    offset += 1
    for _ in 0..<numPPS {
        guard offset + 2 <= data.count else { throw MoQSessionError.missingCodecDescription }
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        guard offset + length <= data.count else { throw MoQSessionError.missingCodecDescription }
        parameterSets.append(data.subdata(in: offset..<(offset + length)))
        offset += length
    }

    guard !parameterSets.isEmpty else {
        throw MoQSessionError.missingCodecDescription
    }

    return ParameterSetCollection(sets: parameterSets)
}

/// Parse an HVCC (HEVC Decoder Configuration Record) into VPS + SPS + PPS parameter sets.
///
/// HVCC layout (ISO 14496-15):
/// ```
/// bytes 0-21:  general configuration fields
/// byte 22:     numOfArrays
/// for each array:
///   byte 0:    array_completeness (1 bit) | reserved (1 bit) | NAL_unit_type (6 bits)
///   byte 1-2:  numNalus (big-endian)
///   for each NALU:
///     byte 0-1:  nalUnitLength (big-endian)
///     bytes:     NAL unit data
/// ```
private func parseHVCCParameterSets(_ data: Data) throws -> ParameterSetCollection {
    guard data.count >= 23 else {
        throw MoQSessionError.missingCodecDescription
    }

    var offset = 22
    let numArrays = Int(data[offset])
    offset += 1

    var parameterSets: [Data] = []

    for _ in 0..<numArrays {
        guard offset + 3 <= data.count else { throw MoQSessionError.missingCodecDescription }
        // Skip NAL unit type byte
        offset += 1
        let numNalus = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        for _ in 0..<numNalus {
            guard offset + 2 <= data.count else { throw MoQSessionError.missingCodecDescription }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { throw MoQSessionError.missingCodecDescription }
            parameterSets.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
    }

    guard !parameterSets.isEmpty else {
        throw MoQSessionError.missingCodecDescription
    }

    return ParameterSetCollection(sets: parameterSets)
}
