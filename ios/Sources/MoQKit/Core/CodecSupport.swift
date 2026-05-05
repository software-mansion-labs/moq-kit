import AVFoundation
import CoreMedia
import MoQKitFFI
import VideoToolbox

internal struct CodecSupportResult {
    let isSupported: Bool
    let reason: String?

    static let supported = CodecSupportResult(isSupported: true, reason: nil)

    static func unsupported(_ reason: String) -> CodecSupportResult {
        CodecSupportResult(isSupported: false, reason: reason)
    }
}

internal enum CodecSupport {
    static func videoEncoder(_ config: VideoEncoderConfig) -> CodecSupportResult {
        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264:
            codecType = kCMVideoCodecType_H264
        case .h265:
            codecType = kCMVideoCodecType_HEVC
        }

        var sessionRef: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionRef
        )

        guard status == noErr, let session = sessionRef else {
            return .unsupported("Failed to create \(config.codec) encoder: \(status)")
        }

        VTCompressionSessionInvalidate(session)
        return .supported
    }

    static func audioEncoder(_ config: AudioEncoderConfig) -> CodecSupportResult {
        let formatID: AudioFormatID
        switch config.codec {
        case .aac:
            formatID = kAudioFormatMPEG4AAC
        case .opus:
            formatID = kAudioFormatOpus
        }

        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: config.sampleRate,
                channels: AVAudioChannelCount(config.channels),
                interleaved: false
            )
        else {
            return .unsupported("Failed to create PCM input format")
        }

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: formatID == kAudioFormatMPEG4AAC ? 1024 : UInt32(config.sampleRate * 0.020),
            mBytesPerFrame: 0,
            mChannelsPerFrame: config.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        guard let outputFormat = AVAudioFormat(streamDescription: &outputASBD) else {
            return .unsupported("Failed to create \(config.codec) output format")
        }

        guard AVAudioConverter(from: inputFormat, to: outputFormat) != nil else {
            return .unsupported("Failed to create \(config.codec) encoder")
        }

        return .supported
    }

    static func videoPlayback(_ config: MoqVideo) -> CodecSupportResult {
        let codec = config.codec.lowercased()
        let codecType: CMVideoCodecType
        if codec.hasPrefix("avc") {
            codecType = kCMVideoCodecType_H264
        } else if codec.hasPrefix("hev") || codec.hasPrefix("hvc") {
            codecType = kCMVideoCodecType_HEVC
        } else if codec.hasPrefix("av0") {
            codecType = kCMVideoCodecType_AV1
        } else {
            return .unsupported("Unsupported video codec: \(config.codec)")
        }

        let formatDescription: CMFormatDescription
        do {
            if config.description != nil {
                formatDescription = try SampleBufferFactory.makeVideoFormatDescription(from: config)
            } else {
                formatDescription = try makeProbeVideoFormatDescription(
                    codecType: codecType,
                    width: Int32(config.coded?.width ?? 1920),
                    height: Int32(config.coded?.height ?? 1080)
                )
            }
        } catch {
            return .unsupported("Invalid \(config.codec) video description: \(error)")
        }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            return .unsupported("Failed to create \(config.codec) video decoder: \(status)")
        }

        VTDecompressionSessionInvalidate(session)
        return .supported
    }

    static func audioPlayback(_ config: MoqAudio) -> CodecSupportResult {
        do {
            _ = try AudioDecoder(config: config)
            return .supported
        } catch SessionError.unsupportedCodec(_) {
            return .unsupported("Unsupported audio codec: \(config.codec)")
        } catch {
            return .unsupported("No \(config.codec) audio decoder is available: \(error)")
        }
    }

    private static func makeProbeVideoFormatDescription(
        codecType: CMVideoCodecType,
        width: Int32,
        height: Int32
    ) throws -> CMFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw SessionError.formatDescriptionFailed(status)
        }
        return formatDescription
    }
}

public extension VideoEncoderConfig {
    /// Video codecs that can be encoded on the current device with default settings.
    static func supportedCodecs() -> [VideoCodec] {
        VideoCodec.allCases.filter { VideoEncoderConfig(codec: $0).isSupported }
    }

    /// Whether this exact encoder configuration can be created on the current device.
    var isSupported: Bool {
        CodecSupport.videoEncoder(self).isSupported
    }

    /// Human-readable reason this configuration is unsupported, or `nil` when supported.
    var unsupportedReason: String? {
        CodecSupport.videoEncoder(self).reason
    }
}

public extension AudioEncoderConfig {
    /// Audio codecs that can be encoded on the current device with default settings.
    static func supportedCodecs() -> [AudioCodec] {
        AudioCodec.allCases.filter { AudioEncoderConfig(codec: $0).isSupported }
    }

    /// Whether this exact encoder configuration can be created on the current device.
    var isSupported: Bool {
        CodecSupport.audioEncoder(self).isSupported
    }

    /// Human-readable reason this configuration is unsupported, or `nil` when supported.
    var unsupportedReason: String? {
        CodecSupport.audioEncoder(self).reason
    }
}

public extension VideoTrackInfo {
    /// Whether this track can be decoded on the current device.
    var isPlayable: Bool {
        CodecSupport.videoPlayback(rawConfig).isSupported
    }

    /// Human-readable reason this track is not playable, or `nil` when playable.
    var unsupportedReason: String? {
        CodecSupport.videoPlayback(rawConfig).reason
    }
}

public extension AudioTrackInfo {
    /// Whether this track can be decoded on the current device.
    var isPlayable: Bool {
        CodecSupport.audioPlayback(rawConfig).isSupported
    }

    /// Human-readable reason this track is not playable, or `nil` when playable.
    var unsupportedReason: String? {
        CodecSupport.audioPlayback(rawConfig).reason
    }
}

public extension Catalog {
    /// Video tracks from this catalog that can be decoded on the current device.
    var playableVideoTracks: [VideoTrackInfo] {
        videoTracks.filter(\.isPlayable)
    }

    /// Audio tracks from this catalog that can be decoded on the current device.
    var playableAudioTracks: [AudioTrackInfo] {
        audioTracks.filter(\.isPlayable)
    }
}
