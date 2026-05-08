import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - VideoRenderer

/// Video playback pipeline: drains compressed frames from a `VideoRendererTrack` into
/// `AVSampleBufferDisplayLayer` (which handles VideoToolbox decoding internally).
///
/// The app-owned jitter buffer remains the latency policy source. AVFoundation's queued
/// renderer is fed only a small decode/render lead ahead of the current media clock.
///
/// Supports seamless rendition switching via an active + pending track model:
/// - The active track feeds the display layer continuously.
/// - A pending track accumulates incoming frames in the background.
/// - The drain loop runs a `SwapPhase` state machine: it discards stale pending frames,
///   waits for a viable keyframe, then either cuts in seamlessly (no flush) when the
///   active track reaches that PTS, or flushes the display layer and swaps immediately
///   when the pending track is too far behind. Emergency swap fires when the active
///   track drains empty.
///
/// Thread safety: `VideoRendererTrack.insert` is called from the ingest task; the
/// `requestMediaDataWhenReady` callback (and all mutations of `activeTrack`/`pendingTrack`)
/// run on `enqueueQueue`.
final class VideoRenderer: @unchecked Sendable {
    private static let enqueueQueueKey = DispatchSpecificKey<Void>()

    let layer: AVSampleBufferDisplayLayer

    // MARK: - Pending-track swap state machine

    private enum SwapPhase {
        /// Pending track set; dropping stale frames, waiting for a recent keyframe.
        case awaitingKeyframe
        /// Found a keyframe at `keyframePts`; waiting for active track to reach that PTS,
        /// then swap without flushing the display layer.
        case cuttingIn(keyframePts: UInt64)
        /// Pending track too far behind; flush display layer and swap immediately.
        case flushAndSwap
    }

    private struct RenderDelay {
        let frontDisplayTimeUs: UInt64
        let playheadUs: UInt64
        let renderLeadUs: UInt64
    }

    private var activeTrack: VideoRendererTrack
    private var pendingTrack: VideoRendererTrack?
    private var pendingPhase: SwapPhase?
    private var onTrackActivated: (() -> Void)?

    private let enqueueQueue: DispatchQueue
    private let timing: any MediaClock
    private let timestampAligner: MediaTimestampAligner?
    private var timelineStarted: Bool
    private let metrics: PlaybackStatsTracker
    private var lastEnqueuedPTS: CMTime = .invalid
    private var lastKnownClockTimeUs: UInt64 = 0
    private var pendingStallCheck: DispatchWorkItem?
    private var pendingDrainWakeup: DispatchWorkItem?
    private var hasLoggedFirstEnqueue = false
    private var hasLoggedNoActiveFrame = false

    /// Frames older than this relative to the active PTS are discarded from the pending
    /// buffer while scanning for a cut-in keyframe (500 ms).
    private let cutInWindowUs: Int64 = 500_000
    /// If the first pending keyframe is more than this behind the active PTS, use the
    /// flush-and-swap strategy instead of cut-in (2 s).
    private let flushThresholdUs: Int64 = 2_000_000
    private let ptsCorrectionThresholdUs: Int64 = 2_000_000
    private let fallbackRenderLeadUs: UInt64 = 50_000
    private let maxRenderLeadUs: UInt64 = 100_000
    private let clockRetargetToleranceUs: UInt64 = 20_000

    init(
        timing: any MediaClock,
        timestampAligner: MediaTimestampAligner? = nil,
        track: VideoRendererTrack,
        layer: AVSampleBufferDisplayLayer,
        metrics: PlaybackStatsTracker
    ) {
        self.layer = layer
        self.timing = timing
        self.timestampAligner = timestampAligner
        self.metrics = metrics
        self.activeTrack = track
        let enqueueQueue = DispatchQueue(
            label: "com.swmansion.MoQKit.VideoEnqueue", qos: .userInteractive)
        enqueueQueue.setSpecific(key: Self.enqueueQueueKey, value: ())
        self.enqueueQueue = enqueueQueue

        timing.attachVideoLayer(layer)
        self.timelineStarted = !timing.isVideoDriven
    }

    // MARK: - Public API

    /// Arms `requestMediaDataWhenReady` and registers the active track's data-available callback.
    func start() {
        let queue = self.enqueueQueue
        activeTrack.setOnDataAvailable(makeDataAvailableCallback())
        queue.async { self.armVideoEnqueue() }
        KitLogger.player.debug(
            "VideoRenderer started clock=\(self.timing.isVideoDriven ? "video-driven" : "audio-driven")"
        )
    }

    /// Stops requesting media data, removes track callbacks, pauses the clock if owned.
    func stop() {
        syncOnEnqueueQueue {
            KitLogger.player.debug(
                "VideoRenderer stopping clock=\(self.timing.isVideoDriven ? "video-driven" : "audio-driven"), timelineStarted=\(self.timelineStarted), bufferFillMs=\(self.activeTrack.depthMs), hasPendingTrack=\(self.pendingTrack != nil)"
            )
            activeTrack.setOnDataAvailable(nil)
            pendingTrack?.setOnDataAvailable(nil)
            pendingTrack = nil
            pendingPhase = nil
            onTrackActivated = nil

            layer.stopRequestingMediaData()
            if timing.isVideoDriven {
                timing.setRate(0)
            }
            timelineStarted = !timing.isVideoDriven
            timing.detachVideoLayer(layer)

            pendingStallCheck?.cancel()
            pendingStallCheck = nil
            pendingDrainWakeup?.cancel()
            pendingDrainWakeup = nil
            lastEnqueuedPTS = .invalid
            lastKnownClockTimeUs = 0
            hasLoggedFirstEnqueue = false
            hasLoggedNoActiveFrame = false
        }
    }

    /// Flushes the active track's jitter buffer and removes the displayed image.
    func flush() {
        syncOnEnqueueQueue {
            KitLogger.player.debug(
                "VideoRenderer flushing active track, bufferFillMs=\(self.activeTrack.depthMs)")
            activeTrack.flush()
            layer.flushAndRemoveImage()
            pendingStallCheck?.cancel()
            pendingStallCheck = nil
            pendingDrainWakeup?.cancel()
            pendingDrainWakeup = nil
            lastEnqueuedPTS = .invalid
            hasLoggedNoActiveFrame = false
        }
    }

    /// Installs a pending track. The drain loop's `SwapPhase` state machine will
    /// decide between a seamless cut-in and a flush-and-swap, then call `performSwap`.
    /// `onActivated` is called on `enqueueQueue` at the moment of the swap.
    func setPendingTrack(_ track: VideoRendererTrack, onActivated: @escaping () -> Void) {
        enqueueQueue.async {
            KitLogger.player.debug("VideoRenderer installed pending track for seamless switch")
            // Discard any previous pending track without firing its callback.
            self.pendingTrack?.setOnDataAvailable(nil)
            track.setBufferState(.pending)
            self.pendingTrack = track
            self.pendingPhase = .awaitingKeyframe
            self.onTrackActivated = onActivated
            // Re-arm so the loop re-evaluates the swap strategy when pending gets data.
            track.setOnDataAvailable(self.makeDataAvailableCallback())
        }
    }

    /// Update the target buffering depth for the active track.
    func updateTargetBuffering(ms: UInt64) {
        enqueueQueue.async {
            let activeBecamePlayable = self.activeTrack.updateTargetBuffering(ms: ms)
            self.pendingTrack?.updateTargetBuffering(ms: ms)
            if self.timing.isVideoDriven, self.timelineStarted {
                self.syncClockToTargetLatency()
            }
            if self.timing.isVideoDriven || activeBecamePlayable {
                self.armVideoEnqueue()
            }
        }
    }

    var bufferFillMs: Double { syncOnEnqueueQueue { activeTrack.depthMs } }

    var hasPendingTrack: Bool { syncOnEnqueueQueue { pendingTrack != nil } }

    // MARK: - Private: drain loop

    private func armVideoEnqueue() {
        layer.requestMediaDataWhenReady(on: enqueueQueue) { [weak self] in
            guard let self else { return }

            self.pendingDrainWakeup?.cancel()
            self.pendingDrainWakeup = nil

            guard self.prepareClockForDrain() else {
                self.layer.stopRequestingMediaData()
                return
            }

            while self.layer.isReadyForMoreMediaData {
                self.advancePendingTrackSwapIfNeeded()

                guard let front = self.activeTrack.peekFront() else {
                    self.handleNoActiveFrame()
                    return
                }

                if let delay = self.renderDelay(forVideoTimestampUs: front.timestampUs) {
                    self.layer.stopRequestingMediaData()
                    self.scheduleDrainWakeup(delay)
                    return
                }

                guard self.enqueueNextActiveFrame() else {
                    self.handleNoActiveFrame()
                    return
                }
            }
        }
    }

    private func prepareClockForDrain() -> Bool {
        guard timing.isVideoDriven else { return true }

        if !timelineStarted {
            return startClockIfReady()
        }

        syncClockToTargetLatency()
        return true
    }

    private func syncOnEnqueueQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.enqueueQueueKey) != nil {
            return try body()
        }
        return try enqueueQueue.sync(execute: body)
    }

    private func advancePendingTrackSwapIfNeeded() {
        guard let pending = pendingTrack, let phase = pendingPhase else { return }

        let sourcePlayheadUs = currentSourceVideoTimeUs()

        switch phase {
        case .awaitingKeyframe:
            discardStalePendingFrames(from: pending, sourcePlayheadUs: sourcePlayheadUs)
            updatePendingPhaseFromKeyframe(in: pending, sourcePlayheadUs: sourcePlayheadUs)

        case .cuttingIn(let keyframePts):
            pending.discardNonKeyframesBeforePts(keyframePts)
            if sourcePlayheadUs >= keyframePts {
                pending.setBufferState(.playing)
                performSwap(to: pending)
            }

        case .flushAndSwap:
            layer.flushAndRemoveImage()
            if let keyframePts = pending.firstKeyframePts {
                pending.discardNonKeyframesBeforePts(keyframePts)
            }
            pending.setBufferState(.playing)
            performSwap(to: pending)
        }
    }

    private func discardStalePendingFrames(
        from pending: VideoRendererTrack,
        sourcePlayheadUs: UInt64
    ) {
        while let front = pending.peekFront(),
            !front.isKeyframe,
            Int64(sourcePlayheadUs) - Int64(front.timestampUs) > cutInWindowUs
        {
            pending.discardFront()
        }
    }

    private func updatePendingPhaseFromKeyframe(
        in pending: VideoRendererTrack,
        sourcePlayheadUs: UInt64
    ) {
        guard let keyframePts = pending.firstKeyframePts else { return }

        let gap = Int64(sourcePlayheadUs) - Int64(keyframePts)
        pendingPhase =
            gap > flushThresholdUs
            ? .flushAndSwap
            : .cuttingIn(keyframePts: keyframePts)
    }

    private func renderDelay(forVideoTimestampUs timestampUs: UInt64) -> RenderDelay? {
        guard timing.isVideoDriven else { return nil }

        let playheadUs = currentPlaybackTimeUs()
        let leadUs = renderLeadUs()
        let renderBoundUs = addClamping(playheadUs, leadUs)
        let frontDisplayTimeUs = displayTimeUs(forVideoTimeUs: timestampUs)

        guard frontDisplayTimeUs > renderBoundUs else { return nil }
        return RenderDelay(
            frontDisplayTimeUs: frontDisplayTimeUs,
            playheadUs: playheadUs,
            renderLeadUs: leadUs
        )
    }

    @discardableResult
    private func enqueueNextActiveFrame() -> Bool {
        let (entry, playable) = activeTrack.dequeue()
        guard let entry else { return false }

        if playable {
            metrics.recordVideoFrameDisplayed()
        } else {
            metrics.recordVideoFrameDropped()
        }

        let displaySample = displaySampleBuffer(
            for: entry.item.sampleBuffer,
            sourceTimestampUs: entry.timestampUs)

        if !playable {
            doNotDisplaySample(displaySample.sampleBuffer)
        }

        layer.enqueue(displaySample.sampleBuffer)
        lastEnqueuedPTS = displaySample.presentationTime
        hasLoggedNoActiveFrame = false
        if !hasLoggedFirstEnqueue {
            hasLoggedFirstEnqueue = true
            KitLogger.player.debug(
                "VideoRenderer enqueued first frame sourceTimestampUs=\(entry.timestampUs), presentationTimeUs=\(MediaClockTime.timestampUs(from: displaySample.presentationTime)), playable=\(playable), bufferFillMs=\(self.activeTrack.depthMs)"
            )
        }
        return true
    }

    private func startClockIfReady() -> Bool {
        guard activeTrack.state == JitterBuffer<VideoRendererSample>.State.playing else {
            return false
        }
        guard
            let sourceStartUs = activeTrack.targetPlaybackPTS()
                ?? activeTrack.peekFront()?.timestampUs
        else {
            return false
        }

        let startUs = displayTimeUs(forVideoTimeUs: sourceStartUs)
        timelineStarted = true
        lastKnownClockTimeUs = startUs
        timing.setRate(1.0, timeUs: startUs)
        KitLogger.player.debug(
            "VideoRenderer started video-driven clock sourceStartUs=\(sourceStartUs), displayStartUs=\(startUs), bufferFillMs=\(self.activeTrack.depthMs)"
        )
        return true
    }

    private func syncClockToTargetLatency() {
        guard let desiredSourceUs = activeTrack.targetPlaybackPTS() else { return }

        let desiredPlayheadUs = displayTimeUs(forVideoTimeUs: desiredSourceUs)
        let currentPlayheadUs = currentPlaybackTimeUs()

        if desiredPlayheadUs > addClamping(currentPlayheadUs, clockRetargetToleranceUs) {
            lastKnownClockTimeUs = desiredPlayheadUs
            timing.setRate(1.0, timeUs: desiredPlayheadUs)
        } else if currentPlayheadUs > addClamping(desiredPlayheadUs, clockRetargetToleranceUs) {
            lastKnownClockTimeUs = currentPlayheadUs
            timing.setRate(0)
            scheduleDrainWakeup(afterUs: currentPlayheadUs - desiredPlayheadUs)
        } else {
            timing.setRate(1.0)
        }
    }

    private func handleNoActiveFrame() {
        layer.stopRequestingMediaData()
        if !hasLoggedNoActiveFrame {
            hasLoggedNoActiveFrame = true
        }

        // Emergency swap: active drained completely but pending has a keyframe.
        if let pending = pendingTrack,
            pending.peekFront()?.isKeyframe == true
        {
            pending.setBufferState(.playing)
            performSwap(to: pending)
            armVideoEnqueue()
            return
        }

        pendingStallCheck?.cancel()
        let currentTime = timing.currentTime()
        if lastEnqueuedPTS.isValid && currentTime < lastEnqueuedPTS {
            let remaining = CMTimeSubtract(lastEnqueuedPTS, currentTime)
            let delaySec = max(0, CMTimeGetSeconds(remaining))
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingStallCheck = nil
                self?.metrics.videoStallBegan()
            }
            pendingStallCheck = workItem
            enqueueQueue.asyncAfter(deadline: .now() + delaySec, execute: workItem)
        } else {
            metrics.videoStallBegan()
        }
    }

    private func scheduleDrainWakeup(_ delay: RenderDelay) {
        let wakeAtUs =
            delay.frontDisplayTimeUs > delay.renderLeadUs
            ? delay.frontDisplayTimeUs - delay.renderLeadUs
            : 0
        let delayUs = wakeAtUs > delay.playheadUs ? wakeAtUs - delay.playheadUs : 0
        scheduleDrainWakeup(afterUs: delayUs)
    }

    private func scheduleDrainWakeup(afterUs delayUs: UInt64) {
        pendingDrainWakeup?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingDrainWakeup = nil
            self?.armVideoEnqueue()
        }
        pendingDrainWakeup = workItem
        enqueueQueue.asyncAfter(
            deadline: .now() + Double(delayUs) / 1_000_000.0,
            execute: workItem
        )
    }

    private func currentPlaybackTimeUs() -> UInt64 {
        let clockTimeUs = timing.currentTimeUs
        if clockTimeUs >= lastKnownClockTimeUs {
            lastKnownClockTimeUs = clockTimeUs
            return clockTimeUs
        }
        return lastKnownClockTimeUs
    }

    private func currentSourceVideoTimeUs() -> UInt64 {
        let playbackTimeUs = currentPlaybackTimeUs()
        guard let timestampAligner else { return playbackTimeUs }
        return timestampAligner.videoTime(
            audioTime: playbackTimeUs,
            threshold: ptsCorrectionThresholdUs)
    }

    private func displayTimeUs(forVideoTimeUs timestampUs: UInt64) -> UInt64 {
        guard let timestampAligner else { return timestampUs }
        return timestampAligner.audioTime(
            videoTime: timestampUs,
            threshold: ptsCorrectionThresholdUs)
    }

    private func renderLeadUs() -> UInt64 {
        guard let frameIntervalUs = activeTrack.frontFrameIntervalUs,
            frameIntervalUs > 0
        else {
            return fallbackRenderLeadUs
        }

        return min(multiplyClamping(frameIntervalUs, by: 3), maxRenderLeadUs)
    }

    private func addClamping(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func multiplyClamping(_ value: UInt64, by multiplier: UInt64) -> UInt64 {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? UInt64.max : result.partialValue
    }

    /// Atomically promotes `newTrack` to active, fires `onTrackActivated`, and re-registers
    /// the data-available callback. Must be called on `enqueueQueue`.
    private func performSwap(to newTrack: VideoRendererTrack) {
        activeTrack.setOnDataAvailable(nil)
        activeTrack = newTrack
        pendingTrack = nil
        pendingPhase = nil
        newTrack.setOnDataAvailable(makeDataAvailableCallback())
        // Current rendition switching assumes all video tracks share one timestamp domain.
        // If future renditions do not, MediaTimestampAligner needs per-video-track live
        // edges or a reset/recompute when the pending track becomes active.
        KitLogger.player.debug("VideoRenderer: swapped to pending track")
        onTrackActivated?()
        onTrackActivated = nil
    }

    /// Returns the closure registered with each track's `setOnDataAvailable`.
    private func makeDataAvailableCallback() -> () -> Void {
        let queue = enqueueQueue
        let metricsRef = metrics
        return { [weak self] in
            queue.async {
                guard let self else { return }
                self.pendingStallCheck?.cancel()
                self.pendingStallCheck = nil
                metricsRef.videoStallEnded()
                self.armVideoEnqueue()
            }
        }
    }

    private func displaySampleBuffer(
        for sampleBuffer: CMSampleBuffer,
        sourceTimestampUs: UInt64
    ) -> (sampleBuffer: CMSampleBuffer, presentationTime: CMTime) {
        let sourceTime = CMTime(value: CMTimeValue(sourceTimestampUs), timescale: 1_000_000)
        guard let timestampAligner,
            let offset = timestampAligner.videoOffset(threshold: ptsCorrectionThresholdUs)
        else {
            return (sampleBuffer, sourceTime)
        }
        let correctedTimestampUs = timestampAligner.audioTime(
            videoTime: sourceTimestampUs,
            threshold: ptsCorrectionThresholdUs)
        guard correctedTimestampUs != sourceTimestampUs else { return (sampleBuffer, sourceTime) }

        guard
            let retimed = Self.copySampleBuffer(
                sampleBuffer,
                shiftingTimingByUs: offset)
        else {
            return (sampleBuffer, sourceTime)
        }

        return (
            retimed,
            CMTime(value: CMTimeValue(correctedTimestampUs), timescale: 1_000_000)
        )
    }

    private static func copySampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        shiftingTimingByUs correctionUs: Int64
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(
            sampleBuffer,
            at: 0,
            timingInfoOut: &timing
        )
        guard timingStatus == noErr, timing.presentationTimeStamp.isValid else { return nil }

        let correction = CMTime(value: CMTimeValue(correctionUs), timescale: 1_000_000)
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, correction)
        if timing.decodeTimeStamp.isValid {
            timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, correction)
        }

        var retimed: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard copyStatus == noErr else { return nil }
        return retimed
    }

    private func doNotDisplaySample(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true)
        else { return }

        let dictPtr = CFArrayGetValueAtIndex(attachments, 0)
        let mutableDict = unsafeBitCast(dictPtr, to: CFMutableDictionary.self)

        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque()
        let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(mutableDict, key, value)
    }
}
