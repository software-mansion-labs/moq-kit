import AVFoundation
import CoreMedia
import QuartzCore
import MoqFFI

// MARK: - VideoRenderer

protocol VideoRendererDelegate: AnyObject, Sendable {
    func videoRenderer(
        _ renderer: VideoRenderer,
        didStartPlayback context: PlaybackStartContext,
        presentationTimeUs: UInt64,
        clockTimeUs: UInt64,
        buffer: Duration
    )
}

/// Video playback pipeline: drains compressed frames from a `VideoRendererTrack` into
/// `AVSampleBufferDisplayLayer` (which handles VideoToolbox decoding internally).
///
/// The app-owned frame buffer remains the latency policy source. AVFoundation's queued
/// renderer is fed only a small decode/render lead ahead of the current media clock.
///
/// Supports seamless rendition switching via an active + pending track model:
/// - The active track feeds the display layer continuously.
/// - A pending track accumulates incoming frames in the background.
/// - The drain loop runs a rendition-switch state machine: it discards stale pending frames,
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

    private struct RenderDelay {
        let frontDisplayTimeUs: UInt64
        let playheadUs: UInt64
        let renderLeadUs: UInt64
    }

    // MARK: - Rendering surface

    let layer: AVSampleBufferDisplayLayer
    private let renderTarget: VideoRenderTarget

    // MARK: - Track-switch state

    private var activeTrack: VideoRendererTrack
    private var pendingTrack: VideoRendererTrack?
    private var onTrackActivated: (() -> Void)?
    private var onTrackAborted: (() -> Void)?

    // MARK: - Queue and timing dependencies

    private let enqueueQueue: DispatchQueue
    private let timing: any MediaPlaybackClock
    private let timestampMapper: TimestampDomainMapper?
    private let pipelineBus: PipelineBus
    private let stallAttributor: PipelineStallAttributor

    // MARK: - Pipeline policies and controllers

    private let feedScheduler = DisplayFeedScheduler()
    private let clockController = ClockRetargetController()
    private let switchController = RenditionSwitchController()
    private let recoveryController = VideoRecoveryController()
    private let ptsCorrectionThresholdUs: Int64 = 2_000_000

    // MARK: - Playback state

    private var timelineStarted: Bool
    private weak var delegate: (any VideoRendererDelegate)?
    private var lastKnownClockTimeUs: UInt64 = 0
    private var isPlaybackStartEventArmed = true

    // MARK: - Stall state

    private var stallHorizon = VideoPresentationHorizon()
    private var videoStallStartedNanos: UInt64?
    private var videoStallCause: StallCause?

    // MARK: - Scheduled work

    private var pendingStallCheck: DispatchWorkItem?
    private var pendingDrainWakeup: DispatchWorkItem?
    private var pendingSwitchTimeout: DispatchWorkItem?

    // MARK: - Diagnostic state

    private var hasLoggedFirstEnqueue = false
    private var hasLoggedNoActiveFrame = false

    init(
        timing: any MediaPlaybackClock,
        timestampMapper: TimestampDomainMapper? = nil,
        track: VideoRendererTrack,
        layer: AVSampleBufferDisplayLayer,
        delegate: any VideoRendererDelegate,
        pipelineBus: PipelineBus,
        stallAttributor: PipelineStallAttributor
    ) {
        self.layer = layer
        self.renderTarget = VideoRenderTarget(layer: layer)
        self.timing = timing
        self.timestampMapper = timestampMapper
        self.pipelineBus = pipelineBus
        self.stallAttributor = stallAttributor
        self.delegate = delegate
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
            onTrackAborted?()
            onTrackAborted = nil
            switchController.complete()
            onTrackActivated = nil

            renderTarget.stopRequestingMediaData()
            if timing.isVideoDriven {
                timing.setRate(0)
            }
            timelineStarted = !timing.isVideoDriven
            timing.detachVideoLayer(layer)

            pendingStallCheck?.cancel()
            pendingStallCheck = nil
            stallHorizon.reset()
            pendingDrainWakeup?.cancel()
            pendingDrainWakeup = nil
            pendingSwitchTimeout?.cancel()
            pendingSwitchTimeout = nil
            lastKnownClockTimeUs = 0
            isPlaybackStartEventArmed = true
            hasLoggedFirstEnqueue = false
            hasLoggedNoActiveFrame = false
        }
    }

    /// Flushes the active track's frame buffer and removes the displayed image.
    func flush() {
        syncOnEnqueueQueue {
            KitLogger.player.debug(
                "VideoRenderer flushing active track, bufferFillMs=\(self.activeTrack.depthMs)")
            activeTrack.flush()
            renderTarget.flush(removeDisplayedImage: true)
            pendingStallCheck?.cancel()
            pendingStallCheck = nil
            stallHorizon.reset()
            pendingDrainWakeup?.cancel()
            pendingDrainWakeup = nil
            isPlaybackStartEventArmed = true
            hasLoggedNoActiveFrame = false
        }
    }

    /// Installs a pending track. The drain loop's rendition-switch state machine will
    /// decide between a seamless cut-in and a flush-and-swap, then call `performSwap`.
    /// `onActivated` is called on `enqueueQueue` at the moment of the swap.
    func setPendingTrack(
        _ track: VideoRendererTrack,
        onActivated: @escaping () -> Void,
        onAborted: @escaping () -> Void
    ) {
        enqueueQueue.async {
            KitLogger.player.debug("VideoRenderer installed pending track for seamless switch")
            // Discard any previous pending track without firing its callback.
            self.pendingTrack?.setOnDataAvailable(nil)
            self.onTrackAborted?()
            track.setBufferState(.pending)
            self.pendingTrack = track
            self.onTrackActivated = onActivated
            self.onTrackAborted = onAborted
            self.switchController.begin(
                targetTrack: track.trackName,
                nowNanos: DispatchTime.now().uptimeNanoseconds
            )
            self.emitSwitchProgress(.preparing, track: track)
            // Re-arm so the loop re-evaluates the swap strategy when pending gets data.
            track.setOnDataAvailable(self.makeDataAvailableCallback())
            self.scheduleSwitchTimeout()
        }
    }

    /// Update the target buffering depth for the active track.
    func updateTargetBuffering(_ targetBuffering: Duration) {
        enqueueQueue.async {
            let activeBecamePlayable = self.activeTrack.updateTargetBuffering(targetBuffering)
            self.pendingTrack?.updateTargetBuffering(targetBuffering)
            if self.timing.isVideoDriven, self.timelineStarted {
                self.syncClockToTargetLatency()
            }
            if self.timing.isVideoDriven || activeBecamePlayable {
                self.armVideoEnqueue()
            }
        }
    }

    var bufferFill: Duration { syncOnEnqueueQueue { activeTrack.depth } }

    var hasPendingTrack: Bool { syncOnEnqueueQueue { pendingTrack != nil } }

    var activeTimeline: TrackTimeline { syncOnEnqueueQueue { activeTrack.timeline } }

    var activeDiagnosticDepth: BufferDepth {
        syncOnEnqueueQueue { activeTrack.diagnosticDepth }
    }

    // MARK: - Private: drain loop

    private func armVideoEnqueue() {
        renderTarget.requestMediaDataWhenReady(on: enqueueQueue) { [weak self] in
            guard let self else { return }

            self.pendingDrainWakeup?.cancel()
            self.pendingDrainWakeup = nil

            guard self.recoverDisplayIfNeeded() else {
                self.renderTarget.stopRequestingMediaData()
                return
            }

            guard self.prepareClockForDrain() else {
                self.renderTarget.stopRequestingMediaData()
                return
            }

            while self.renderTarget.isReadyForMoreMediaData {
                self.advancePendingTrackSwapIfNeeded()

                guard let front = self.activeTrack.peekFront() else {
                    self.handleNoActiveFrame()
                    return
                }

                if let delay = self.renderDelay(forVideoTimestampUs: front.timestampUs) {
                    self.renderTarget.stopRequestingMediaData()
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
        guard let pending = pendingTrack else { return }

        let sourcePlayheadUs = currentSourceVideoTimeUs()

        if case .abort = switchController.onTime(
            nowNanos: DispatchTime.now().uptimeNanoseconds
        ) {
            abortPendingSwitch()
            return
        }

        if case .preparing = switchController.state {
            discardStalePendingFrames(from: pending, sourcePlayheadUs: sourcePlayheadUs)
            if let keyframePts = pending.firstKeyframePts {
                let decision = switchController.onKeyframeAvailable(
                    activePtsUs: sourcePlayheadUs,
                    keyframePtsUs: keyframePts
                )
                if decision == .flushSwap {
                    emitSwitchProgress(.flushSwap, track: pending)
                } else {
                    emitSwitchProgress(.cutIn, track: pending)
                }
            }
        }

        switch switchController.onActiveProgress(sourcePlayheadUs) {
        case .cutIn(let keyframePts):
            pending.discardNonKeyframesBeforePts(keyframePts)
            pending.setBufferState(.playing)
            performSwap(to: pending)
        case .flushSwap:
            let dropped = activeTrack.diagnosticDepth.frames
            renderTarget.flush(removeDisplayedImage: true)
            stallHorizon.reset()
            emitDisplayFlush(
                reason: .renditionSwitch,
                trigger: "rendition timestamp domains require flush",
                droppedFrames: dropped,
                track: pending
            )
            if let keyframePts = pending.firstKeyframePts {
                pending.discardNonKeyframesBeforePts(keyframePts)
            }
            pending.setBufferState(.playing)
            performSwap(to: pending)
        case .wait, .abort:
            break
        }
    }

    private func discardStalePendingFrames(
        from pending: VideoRendererTrack,
        sourcePlayheadUs: UInt64
    ) {
        while let front = pending.peekFront(),
            !front.isKeyframe,
            switchController.shouldDiscardPendingDelta(
                activePtsUs: sourcePlayheadUs,
                framePtsUs: front.timestampUs
            )
        {
            pending.discardFront()
        }
    }

    private func renderDelay(forVideoTimestampUs timestampUs: UInt64) -> RenderDelay? {
        let playheadUs = currentPlaybackTimeUs()
        let frontDisplayTimeUs = displayTimeUs(forVideoTimeUs: timestampUs)
        guard case .hold = feedScheduler.decision(
            framePtsUs: frontDisplayTimeUs,
            playheadUs: playheadUs,
            isPlaybackCandidate: true
        ) else { return nil }
        return RenderDelay(
            frontDisplayTimeUs: frontDisplayTimeUs,
            playheadUs: playheadUs,
            renderLeadUs: UInt64(PipelinePolicies.render.maxAheadUs)
        )
    }

    @discardableResult
    private func enqueueNextActiveFrame() -> Bool {
        let frontFrameIntervalUs = activeTrack.frontFrameIntervalUs
        let (entry, playable) = activeTrack.dequeue()
        guard let entry else { return false }

        let displaySample = displaySampleBuffer(
            for: entry.item.sampleBuffer,
            sourceTimestampUs: entry.timestampUs)

        let feedDecision = feedScheduler.decision(
            framePtsUs: MediaClockTime.timestampUs(from: displaySample.presentationTime),
            playheadUs: currentPlaybackTimeUs(),
            isPlaybackCandidate: playable
        )
        let visible = feedDecision == .visible
        if !visible {
            doNotDisplaySample(displaySample.sampleBuffer)
            pipelineBus.emit(.frameDropped(
                context: pipelineContext(for: activeTrack),
                stage: .renderer,
                reason: playable ? .lateRender : .staleVsPlayback,
                ptsUs: Int64(clamping: entry.timestampUs),
                count: 1
            ))
        }

        pipelineBus.emit(.decoderInputQueued(
            context: pipelineContext(for: activeTrack),
            ptsUs: Int64(clamping: entry.timestampUs)
        ))
        renderTarget.enqueue(displaySample.sampleBuffer)
        if visible {
            pipelineBus.emit(.frameRendered(
                context: pipelineContext(for: activeTrack),
                ptsUs: Int64(clamping: entry.timestampUs),
                renderNanos: DispatchTime.now().uptimeNanoseconds
            ))
            let shouldEndStall = stallHorizon.recordVisibleFrame(
                sampleBuffer: displaySample.sampleBuffer,
                presentationTime: displaySample.presentationTime,
                frontFrameIntervalUs: frontFrameIntervalUs
            )
            if shouldEndStall {
                endVideoStall()
            }
        }
        hasLoggedNoActiveFrame = false
        if visible {
            emitPlaybackStartIfArmed(
                sourceTimestampUs: entry.timestampUs,
                presentationTimeUs: MediaClockTime.timestampUs(from: displaySample.presentationTime),
                buffer: activeTrack.depth
            )
        }
        if !hasLoggedFirstEnqueue {
            hasLoggedFirstEnqueue = true
            KitLogger.player.debug(
                "VideoRenderer enqueued first frame sourceTimestampUs=\(entry.timestampUs), presentationTimeUs=\(MediaClockTime.timestampUs(from: displaySample.presentationTime)), visible=\(visible), bufferFillMs=\(self.activeTrack.depthMs)"
            )
        }
        return true
    }

    private func emitPlaybackStartIfArmed(
        sourceTimestampUs: UInt64,
        presentationTimeUs: UInt64,
        buffer: Duration
    ) {
        guard isPlaybackStartEventArmed else { return }
        isPlaybackStartEventArmed = false

        let context = PlaybackStartContext(
            kind: .video,
            trackName: activeTrack.trackName,
            sourceTimestampUs: sourceTimestampUs,
            targetBuffering: activeTrack.targetBuffering,
            trackEpoch: activeTrack.trackEpoch
        )

        delegate?.videoRenderer(
            self,
            didStartPlayback: context,
            presentationTimeUs: presentationTimeUs,
            clockTimeUs: max(timing.currentTimeUs, presentationTimeUs),
            buffer: buffer
        )
    }

    private func startClockIfReady() -> Bool {
        guard activeTrack.state == VideoRendererTrack.State.playing else {
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

        let decision = clockController.decision(
            currentUs: currentPlayheadUs,
            targetUs: desiredPlayheadUs
        )
        pipelineBus.emit(.clockRetarget(
            context: pipelineContext(for: activeTrack),
            decision: decision
        ))
        switch decision {
        case .noOp:
            timing.setRate(1.0)
        case .jump(let positionUs):
            let target = UInt64(max(0, positionUs))
            lastKnownClockTimeUs = target
            timing.setRate(1.0, timeUs: target)
        case .nudge(let rate):
            timing.setRate(rate)
        }
    }

    private func handleNoActiveFrame() {
        renderTarget.stopRequestingMediaData()
        if !hasLoggedNoActiveFrame {
            hasLoggedNoActiveFrame = true
        }

        // Emergency swap: active drained completely but pending has a keyframe.
        if promotePendingTrackIfReady() {
            armVideoEnqueue()
            return
        }

        evaluateVideoStallStart()
    }

    private func evaluateVideoStallStart() {
        pendingStallCheck?.cancel()
        pendingStallCheck = nil
        stallHorizon.clearPendingStallMarker()

        guard activeTrack.peekFront() == nil else { return }

        if promotePendingTrackIfReady() {
            armVideoEnqueue()
            return
        }

        switch stallHorizon.evaluateStallStart(at: currentPlaybackTimeUs()) {
        case .wait(let delayUs):
            scheduleVideoStallCheck(afterUs: delayUs)
        case .beginStall:
            beginVideoStall()
        case .alreadyStalled:
            break
        }
    }

    private func scheduleVideoStallCheck(afterUs delayUs: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateVideoStallStart()
        }
        pendingStallCheck = workItem
        enqueueQueue.asyncAfter(
            deadline: .now() + Double(delayUs) / 1_000_000.0,
            execute: workItem
        )
    }

    private func beginVideoStall() {
        let stalledAtUs = currentPlaybackTimeUs()
        lastKnownClockTimeUs = stalledAtUs
        if timing.isVideoDriven {
            timing.setRate(0)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let cause = stallAttributor.cause(
            trackId: activeTrack.trackName,
            mediaKind: .video,
            nowNanos: now,
            fallback: pendingTrack == nil ? .renderStall : .switchStall
        )
        videoStallStartedNanos = now
        videoStallCause = cause
        pipelineBus.emit(.stallStarted(
            context: pipelineContext(for: activeTrack),
            cause: cause
        ))
    }

    private func endVideoStall() {
        if timing.isVideoDriven {
            timing.setRate(1.0)
        }
        if let started = videoStallStartedNanos, let cause = videoStallCause {
            let now = DispatchTime.now().uptimeNanoseconds
            pipelineBus.emit(.stallEnded(
                context: pipelineContext(for: activeTrack),
                cause: cause,
                durationMillis: now >= started ? (now - started) / 1_000_000 : 0
            ))
        }
        videoStallStartedNanos = nil
        videoStallCause = nil
    }

    @discardableResult
    private func promotePendingTrackIfReady() -> Bool {
        guard let pending = pendingTrack,
            pending.peekFront()?.isKeyframe == true
        else {
            return false
        }

        pending.setBufferState(.playing)
        performSwap(to: pending)
        return true
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
        let sourceTime = timestampMapper?.videoTimeUs(
            audioTimeUs: playbackTimeUs,
            thresholdUs: ptsCorrectionThresholdUs
        ) ?? playbackTimeUs
        activeTrack.timeline.onPlaybackPosition(Int64(clamping: sourceTime))
        return sourceTime
    }

    private func displayTimeUs(forVideoTimeUs timestampUs: UInt64) -> UInt64 {
        timestampMapper?.audioTimeUs(
            videoTimeUs: timestampUs,
            thresholdUs: ptsCorrectionThresholdUs
        ) ?? timestampUs
    }

    /// Atomically promotes `newTrack` to active, fires `onTrackActivated`, and re-registers
    /// the data-available callback. Must be called on `enqueueQueue`.
    private func performSwap(to newTrack: VideoRendererTrack) {
        activeTrack.setOnDataAvailable(nil)
        activeTrack = newTrack
        timestampMapper?.setVideoTimeline(newTrack.timeline)
        pendingTrack = nil
        switchController.complete()
        pendingSwitchTimeout?.cancel()
        pendingSwitchTimeout = nil
        isPlaybackStartEventArmed = true
        newTrack.setOnDataAvailable(makeDataAvailableCallback())
        KitLogger.player.debug("VideoRenderer: swapped to pending track")
        emitSwitchProgress(.steady, track: newTrack)
        onTrackActivated?()
        onTrackActivated = nil
        onTrackAborted = nil
    }

    private func scheduleSwitchTimeout() {
        pendingSwitchTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSwitchTimeout = nil
            self.advancePendingTrackSwapIfNeeded()
        }
        pendingSwitchTimeout = work
        enqueueQueue.asyncAfter(
            deadline: .now() + Double(PipelinePolicies.switch.keyframeTimeoutUs) / 1_000_000,
            execute: work
        )
    }

    private func abortPendingSwitch() {
        guard let pending = pendingTrack else { return }
        pending.setOnDataAvailable(nil)
        pending.flush()
        pendingTrack = nil
        pendingSwitchTimeout?.cancel()
        pendingSwitchTimeout = nil
        emitSwitchProgress(.aborted, track: pending)
        onTrackAborted?()
        onTrackAborted = nil
        onTrackActivated = nil
    }

    private func recoverDisplayIfNeeded() -> Bool {
        guard renderTarget.status == .failed
                || renderTarget.requiresFlushToResumeDecoding
        else { return true }

        let trigger = renderTarget.error?.localizedDescription
            ?? "AVFoundation requires a display flush"
        let attempt = recoveryController.onFailure(trigger: trigger)
        let context = pipelineContext(for: activeTrack)
        pipelineBus.emit(.decoderRecovery(
            context: context,
            attempt: attempt.attempt,
            step: attempt.step,
            trigger: attempt.trigger
        ))

        guard attempt.step == .flush else {
            pipelineBus.emit(.transportClosed(
                context: context,
                error: PipelineError(code: "video-renderer-failed", message: trigger)
            ))
            return false
        }

        let dropped = activeTrack.diagnosticDepth.frames
        renderTarget.flush(removeDisplayedImage: false)
        let reset: TimelineDecision<VideoRendererSample> =
            activeTrack.timeline.requestReset()
        activeTrack.flush()
        stallHorizon.reset()
        if case .reset(_, let epoch, _, _) = reset {
            pipelineBus.emit(.discontinuity(
                context: context,
                epoch: epoch,
                reason: .localReset
            ))
        }
        emitDisplayFlush(
            reason: .decoderRecovery,
            trigger: trigger,
            droppedFrames: dropped,
            track: activeTrack
        )
        return true
    }

    private func emitDisplayFlush(
        reason: DecoderFlushReason,
        trigger: String,
        droppedFrames: Int,
        track: VideoRendererTrack
    ) {
        pipelineBus.emit(.decoderFlushed(
            context: pipelineContext(for: track),
            reason: reason,
            trigger: trigger,
            droppedFrames: droppedFrames
        ))
    }

    private func emitSwitchProgress(_ phase: SwitchPhase, track: VideoRendererTrack) {
        pipelineBus.emit(.switchProgress(
            context: pipelineContext(for: track),
            phase: phase
        ))
    }

    private func pipelineContext(for track: VideoRendererTrack) -> PipelineContext {
        PipelineContext(
            trackId: track.trackName,
            mediaKind: .video,
            timestampNanos: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Returns the closure registered with each track's `setOnDataAvailable`.
    private func makeDataAvailableCallback() -> () -> Void {
        let queue = enqueueQueue
        return { [weak self] in
            queue.async {
                guard let self else { return }
                self.pendingStallCheck?.cancel()
                self.pendingStallCheck = nil
                self.stallHorizon.clearPendingStallMarker()
                self.armVideoEnqueue()
            }
        }
    }

    private func displaySampleBuffer(
        for sampleBuffer: CMSampleBuffer,
        sourceTimestampUs: UInt64
    ) -> (sampleBuffer: CMSampleBuffer, presentationTime: CMTime) {
        let sourceTime = CMTime(value: CMTimeValue(sourceTimestampUs), timescale: 1_000_000)
        guard let timestampMapper,
            let offset = timestampMapper.videoOffsetUs(thresholdUs: ptsCorrectionThresholdUs)
        else {
            return (sampleBuffer, sourceTime)
        }
        let correctedTimestampUs = timestampMapper.audioTimeUs(
            videoTimeUs: sourceTimestampUs,
            thresholdUs: ptsCorrectionThresholdUs)
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
