import Foundation
import MoQKitFFI

// MARK: - MoQSize

/// A pair of pixel dimensions used to describe video resolution or display ratio.
public struct MoQSize: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
}

// MARK: - MoQVideoConfig

/// Codec and format parameters for a video rendition.
public struct MoQVideoConfig: Sendable {
    /// Codec identifier string (e.g. `"avc1"`, `"hev1"`, `"av01"`).
    public let codec: String
    /// Coded frame dimensions in pixels. `nil` when not specified by the publisher.
    public let coded: MoQSize?
    /// Display aspect ratio. `nil` when not specified by the publisher.
    public let displayRatio: MoQSize?
    /// Target bitrate in bits per second. `nil` when not specified.
    public let bitrate: UInt64?
    /// Frame rate in frames per second. `nil` when not specified.
    public let framerate: Double?

    init(_ raw: MoqVideo) {
        self.codec = raw.codec
        self.coded = raw.coded.map { MoQSize(width: $0.width, height: $0.height) }
        self.displayRatio = raw.displayRatio.map { MoQSize(width: $0.width, height: $0.height) }
        self.bitrate = raw.bitrate
        self.framerate = raw.framerate
    }
}

extension MoQVideoConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), width=\(coded?.width ?? 0), height=\(coded?.height ?? 0)"
    }
}

// MARK: - MoQAudioConfig

/// Codec and format parameters for an audio rendition.
public struct MoQAudioConfig: Sendable {
    /// Codec identifier string (e.g. `"mp4a.40.2"` for AAC, `"opus"` for Opus).
    public let codec: String
    /// Sample rate in Hz (e.g. `44100`, `48000`).
    public let sampleRate: UInt32
    /// Number of audio channels (e.g. `1` for mono, `2` for stereo).
    public let channelCount: UInt32
    /// Target bitrate in bits per second. `nil` when not specified.
    public let bitrate: UInt64?

    init(_ raw: MoqAudio) {
        self.codec = raw.codec
        self.sampleRate = raw.sampleRate
        self.channelCount = raw.channelCount
        self.bitrate = raw.bitrate
    }
}

extension MoQAudioConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), sampleRate=\(sampleRate), channels=\(channelCount)"
    }
}

// MARK: - Track Info Types

/// A type that describes a single media track within a broadcast.
///
/// Concrete types are ``MoQVideoTrackInfo`` and ``MoQAudioTrackInfo``. Pass an array of
/// `MoQTrackInfo` values to ``MoQPlayer/init(tracks:targetBufferingMs:)`` to start playback.
public protocol MoQTrackInfo: Sendable {
    /// The track name used to subscribe on the relay.
    var name: String { get }
}

/// Describes a video track within a broadcast, including its codec and resolution.
public struct MoQVideoTrackInfo: MoQTrackInfo, @unchecked Sendable {
    /// The track name used to subscribe on the relay.
    public let name: String
    /// Codec, resolution, and format parameters for this video rendition.
    public let config: MoQVideoConfig

    // Internal fields used by MoQPlayer
    let broadcast: MoqBroadcastConsumer
    let rawConfig: MoqVideo

    init(name: String, config: MoqVideo, broadcast: MoqBroadcastConsumer) {
        self.name = name
        self.rawConfig = config
        self.config = MoQVideoConfig(config)
        self.broadcast = broadcast
    }
}

/// Describes an audio track within a broadcast, including its codec and sample rate.
public struct MoQAudioTrackInfo: MoQTrackInfo, @unchecked Sendable {
    /// The track name used to subscribe on the relay.
    public let name: String
    /// Codec, sample rate, and channel configuration for this audio rendition.
    public let config: MoQAudioConfig

    // Internal fields used by MoQPlayer
    let broadcast: MoqBroadcastConsumer
    let rawConfig: MoqAudio

    init(name: String, config: MoqAudio, broadcast: MoqBroadcastConsumer) {
        self.name = name
        self.rawConfig = config
        self.config = MoQAudioConfig(config)
        self.broadcast = broadcast
    }
}

/// Describes the tracks available in a live broadcast at a given relay path.
///
/// Delivered via ``MoQBroadcastEvent/available(_:)`` on ``MoQSession/broadcasts``.
/// Pass ``videoTracks`` and/or ``audioTracks`` to ``MoQPlayer/init(tracks:targetBufferingMs:)``
/// to start playback.
public struct MoQBroadcastInfo: Sendable {
    /// The relay path that identifies this broadcast (e.g. `"live/game1"`).
    public let path: String
    /// Available video renditions. Typically one entry per resolution/bitrate tier.
    public let videoTracks: [MoQVideoTrackInfo]
    /// Available audio renditions. Typically one or more language/codec variants.
    public let audioTracks: [MoQAudioTrackInfo]
}

/// Lifecycle events emitted on ``MoQSession/broadcasts``.
public enum MoQBroadcastEvent: Sendable {
    /// A broadcast became available (or its catalog was updated). The associated
    /// ``MoQBroadcastInfo`` describes its tracks. This event may fire more than once for the
    /// same path if the publisher updates its catalog.
    case available(MoQBroadcastInfo)
    /// The broadcast at the given relay path ended. Any in-progress ``MoQPlayer`` for this
    /// broadcast will receive ``MoQPlayerEvent/trackStopped(_:)`` shortly after.
    case unavailable(path: String)
}
