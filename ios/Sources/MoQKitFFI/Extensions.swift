import Foundation

// Internal debug string helpers for generated UniFFI types.
// Not public — MoQKit uses these for logging only.

extension MoqVideo: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), width=\(coded?.width ?? 0), height=\(coded?.height ?? 0)"
    }
}

extension MoqAudio: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), sampleRate=\(sampleRate), channels=\(channelCount)"
    }
}

extension Container: CustomStringConvertible {
    public var description: String {
        switch self {
        case .legacy:
            return "legacy"
        case .cmaf(let timescale, let trackId):
            return "cmaf{timescale=\(timescale), trackId=\(trackId)}"
        }
    }
}
