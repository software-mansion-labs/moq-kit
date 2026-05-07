import AVFoundation
import CoreMedia
import Foundation

/// Shared playback clock.
final class MediaTimebase: @unchecked Sendable {
    private let cmTimebase: CMTimebase

    convenience init() throws {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard let tb else {
            throw SessionError.invalidConfiguration("Failed to create CMTimebase")
        }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 0)

        self.init(cmTimebase: tb)
    }

    private init(cmTimebase: CMTimebase) {
        self.cmTimebase = cmTimebase
    }

    func setTimeUs(_ timestampUs: UInt64) {
        CMTimebaseSetTime(
            cmTimebase,
            time: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000)
        )
    }

    func setRate(_ rate: Double) {
        CMTimebaseSetRate(cmTimebase, rate: rate)
    }

    func configure(displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.controlTimebase = cmTimebase
    }

    func currentTime() -> CMTime {
        CMTimebaseGetTime(cmTimebase)
    }

    var currentTimeUs: UInt64 {
        let time = currentTime()
        return UInt64(max(0, time.seconds * 1_000_000))
    }
}
