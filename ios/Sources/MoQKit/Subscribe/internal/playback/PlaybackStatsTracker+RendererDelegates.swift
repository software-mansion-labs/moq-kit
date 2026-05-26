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

    func audioRendererDidBeginStall(_ renderer: AudioRenderer) {
        noteStall(kind: .audio, stalled: true)
    }

    func audioRendererDidEndStall(_ renderer: AudioRenderer) {
        noteStall(kind: .audio, stalled: false)
    }

    func audioRenderer(_ renderer: AudioRenderer, didDropFrames count: Int) {
        recordAudioFramesDropped(count)
    }
}

extension PlaybackStatsTracker: VideoRendererDelegate {
    func videoRendererDidBeginStall(_ renderer: VideoRenderer) {
        noteStall(kind: .video, stalled: true)
    }

    func videoRendererDidEndStall(_ renderer: VideoRenderer) {
        noteStall(kind: .video, stalled: false)
    }

    func videoRendererDidDisplayFrame(_ renderer: VideoRenderer) {
        recordVideoFrameDisplayed()
    }

    func videoRendererDidDropFrame(_ renderer: VideoRenderer) {
        recordVideoFrameDropped()
    }

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
