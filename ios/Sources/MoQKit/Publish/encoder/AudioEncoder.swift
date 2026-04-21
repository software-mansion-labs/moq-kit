import CoreMedia
import Foundation

/// Common interface for codec-specific audio encoders.
protocol AudioEncoding {
    func encode(_ sampleBuffer: CMSampleBuffer) -> [EncodedAudioFrame]
    func buildInitData() -> Data
    func stop()
}

/// Coordinates audio encoding by delegating to a codec-specific encoder (AAC or Opus).
final class AudioEncoder: @unchecked Sendable {
    private var encoder: AudioEncoding?
    private var handler: ((EncodedAudioFrame) -> Void)?
    private var sentInitData = false

    let config: AudioEncoderConfig

    init(config: AudioEncoderConfig) {
        self.config = config
    }

    func start(handler: @escaping (EncodedAudioFrame) -> Void) throws {
        self.handler = handler
        sentInitData = false

        switch config.codec {
        case .aac:
            encoder = AACEncoder(config: config)
        case .opus:
            encoder = OpusEncoder(config: config)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        let frames = encoder?.encode(sampleBuffer) ?? []
        for var frame in frames {
            if !sentInitData {
                frame.initData = encoder?.buildInitData()
                sentInitData = true
            }
            handler?(frame)
        }
    }

    func stop() {
        encoder?.stop()
        encoder = nil
        handler = nil
    }
}

// MARK: - Types

struct EncodedAudioFrame {
    let data: Data
    let presentationTime: CMTime
    var initData: Data?
}

/// Codec for audio encoding.
public enum AudioCodec: String, Sendable, Hashable, Codable {
    case aac
    case opus
}

/// Configuration for the audio encoder.
public struct AudioEncoderConfig: Sendable, Codable {
    public var codec: AudioCodec
    public var sampleRate: Double
    public var channels: UInt32
    public var bitrate: UInt32

    public init(
        codec: AudioCodec = .opus,
        sampleRate: Double = 48000,
        channels: UInt32 = 1,
        bitrate: UInt32 = 128_000
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
    }

    var format: String {
        switch codec {
        case .aac: return "aac"
        case .opus: return "opus"
        }
    }
}
