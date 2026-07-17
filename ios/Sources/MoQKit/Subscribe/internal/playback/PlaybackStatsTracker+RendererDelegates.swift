import Foundation

extension PlaybackStatsTracker: AudioRendererDelegate {
    func audioRendererHasPendingPlaybackStart(_ renderer: AudioRenderer) -> Bool {
        isAudioPlaybackStartArmed
    }

    func audioRenderer(
        _ renderer: AudioRenderer,
        didPreparePlaybackStart context: PlaybackStartContext
    ) {
        armAudioPlaybackStart(context)
    }

    func audioRendererDidClearExpectedPlaybackStart(_ renderer: AudioRenderer) {
        disarmAudioPlaybackStart()
    }

    func audioRenderer(
        _ renderer: AudioRenderer,
        didRenderAudioAt timestampUs: UInt64,
        hostTime: UInt64?
    ) {
        audioPlaybackStarted(
            timestampUs: timestampUs,
            hostTime: hostTime
        )
    }
}

extension PlaybackStatsTracker: VideoRendererDelegate {
    func videoRenderer(
        _ renderer: VideoRenderer,
        didStartPlayback context: PlaybackStartContext,
        presentationTimeUs: UInt64,
        clockTimeUs: UInt64,
        buffer: Duration
    ) {
        videoPlaybackStarted(
            context: context,
            presentationTimeUs: presentationTimeUs,
            clockTimeUs: clockTimeUs,
            buffer: buffer
        )
    }
}
