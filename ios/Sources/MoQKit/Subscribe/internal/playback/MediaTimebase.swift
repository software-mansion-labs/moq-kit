import AVFoundation
import CoreMedia
import Foundation

// MARK: - MediaClockTime

enum MediaClockTime {
    static func cmTime(timestampUs: UInt64) -> CMTime {
        CMTime(value: CMTimeValue(min(timestampUs, UInt64(Int64.max))), timescale: 1_000_000)
    }

    static func timestampUs(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.seconds.isNaN else { return 0 }
        let converted = CMTimeConvertScale(
            time,
            timescale: 1_000_000,
            method: .roundHalfAwayFromZero
        )
        guard converted.isValid, converted.value > 0 else { return 0 }
        return UInt64(converted.value)
    }
}

// MARK: - MediaClock

/// Abstraction over a Core Media-backed playback clock.
///
/// Two concrete clocks share this interface:
/// - ``AudioDrivenClock`` (`isVideoDriven == false`): the audio renderer drives the timeline by
///   updating the clock from its render callback. Used whenever audio is present.
/// - ``VideoDrivenClock`` (`isVideoDriven == true`): the video renderer drives the
///   timeline itself. Used for video-only playback.
///
/// `isVideoDriven` lets the video renderer decide whether it must start/pause the clock
/// (video-only mode) or just observe it (audio-driven mode).
protocol MediaClock: AnyObject, Sendable {
    var currentTimeUs: UInt64 { get }
    var isVideoDriven: Bool { get }
    func currentTime() -> CMTime
    func setTimeUs(_ timestampUs: UInt64)
    func setRate(_ rate: Double)
    func setRate(_ rate: Double, timeUs: UInt64)
    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer)
    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer)
}

// MARK: - AudioDrivenClock

/// Shared playback clock.
final class AudioDrivenClock: MediaClock, @unchecked Sendable {
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
            time: MediaClockTime.cmTime(timestampUs: timestampUs)
        )
    }

    func setRate(_ rate: Double) {
        CMTimebaseSetRate(cmTimebase, rate: rate)
    }

    func setRate(_ rate: Double, timeUs: UInt64) {
        setTimeUs(timeUs)
        setRate(rate)
    }

    func configure(displayLayer: AVSampleBufferDisplayLayer) {
        attachVideoLayer(displayLayer)
    }

    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.controlTimebase = cmTimebase
    }

    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.controlTimebase = nil
    }

    func currentTime() -> CMTime {
        CMTimebaseGetTime(cmTimebase)
    }

    var currentTimeUs: UInt64 {
        MediaClockTime.timestampUs(from: currentTime())
    }

    var isVideoDriven: Bool { false }
}

// MARK: - VideoDrivenClock

/// Video-only playback clock backed by `AVSampleBufferRenderSynchronizer`.
final class VideoDrivenClock: MediaClock, @unchecked Sendable {
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    init() {
        self.synchronizer = AVSampleBufferRenderSynchronizer()
        self.synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    func setTimeUs(_ timestampUs: UInt64) {
        synchronizer.setRate(
            synchronizer.rate,
            time: MediaClockTime.cmTime(timestampUs: timestampUs)
        )
    }

    func setRate(_ rate: Double) {
        synchronizer.setRate(Float(rate), time: .invalid)
    }

    func setRate(_ rate: Double, timeUs: UInt64) {
        synchronizer.setRate(Float(rate), time: MediaClockTime.cmTime(timestampUs: timeUs))
    }

    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        if attachedLayer === displayLayer { return }

        if let attachedLayer {
            synchronizer.removeRenderer(
                attachedLayer,
                at: .invalid,
                completionHandler: nil
            )
        }

        displayLayer.controlTimebase = nil
        synchronizer.addRenderer(displayLayer)
        attachedLayer = displayLayer
    }

    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard attachedLayer === displayLayer else { return }
        synchronizer.removeRenderer(displayLayer, at: .invalid, completionHandler: nil)
        attachedLayer = nil
    }

    func currentTime() -> CMTime {
        synchronizer.currentTime()
    }

    var currentTimeUs: UInt64 {
        MediaClockTime.timestampUs(from: currentTime())
    }

    var isVideoDriven: Bool { true }
}
