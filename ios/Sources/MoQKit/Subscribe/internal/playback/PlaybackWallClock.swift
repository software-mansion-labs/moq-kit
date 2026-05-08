import CoreMedia
import Foundation

enum PlaybackTimeUnit {
    case ms
    case us
    case ns
}

protocol PlaybackWallClock: Sendable {
    func now(in unit: PlaybackTimeUnit) -> Int64
}

struct HostPlaybackWallClock: PlaybackWallClock {
    func now(in unit: PlaybackTimeUnit) -> Int64 {
        switch unit {
        case .ms:
            return hostTime(timescale: 1_000).value
        case .us:
            return hostTime(timescale: 1_000_000).value
        case .ns:
            return hostTime(timescale: 1_000_000_000).value
        }
    }

    private func hostTime(timescale: CMTimeScale) -> CMTime {
        CMTimeConvertScale(
            CMClockGetTime(CMClockGetHostTimeClock()),
            timescale: timescale,
            method: .roundHalfAwayFromZero
        )
    }
}
