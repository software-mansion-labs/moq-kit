import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - VideoRenderer

/// Video playback pipeline: drains compressed frames from a `VideoRendererTrack` into
/// `AVSampleBufferDisplayLayer` (which handles VideoToolbox decoding internally).
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
    let layer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase

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

    private var activeTrack: VideoRendererTrack
    private var pendingTrack: VideoRendererTrack?
    private var pendingPhase: SwapPhase?
    private var onTrackActivated: (() -> Void)?

    private let enqueueQueue: DispatchQueue
    private let isTimebaseOwner: Bool
    private var timebaseStarted: Bool
    private let metrics: PlaybackMetricsAccumulator
    private var lastEnqueuedPTSus: UInt64 = 0
    private var lastEnqueuedPTS: CMTime = .invalid
    private var pendingStallCheck: DispatchWorkItem?

    /// Frames older than this relative to the active PTS are discarded from the pending
    /// buffer while scanning for a cut-in keyframe (500 ms).
    private let cutInWindowUs: Int64 = 500_000
    /// If the first pending keyframe is more than this behind the active PTS, use the
    /// flush-and-swap strategy instead of cut-in (2 s).
    private let flushThresholdUs: Int64 = 2_000_000

    init(
        timebase: CMTimebase,
        isTimebaseOwner: Bool,
        track: VideoRendererTrack,
        layer: AVSampleBufferDisplayLayer,
        metrics: PlaybackMetricsAccumulator
    ) {
        self.layer = layer
        self.timebase = timebase
        self.isTimebaseOwner = isTimebaseOwner
        self.metrics = metrics
        self.activeTrack = track
        self.enqueueQueue = DispatchQueue(
            label: "com.swmansion.MoQKit.VideoEnqueue", qos: .userInteractive)

        layer.controlTimebase = timebase
        self.timebaseStarted = !isTimebaseOwner
    }

    // MARK: - Public API

    /// Arms `requestMediaDataWhenReady` and registers the active track's data-available callback.
    func start() {
        let queue = self.enqueueQueue
        activeTrack.setOnDataAvailable(makeDataAvailableCallback())
        queue.async { self.armVideoEnqueue() }
        KitLogger.player.debug("VideoRenderer started")
    }

    /// Stops requesting media data, removes track callbacks, pauses timebase if owned.
    func stop() {
        activeTrack.setOnDataAvailable(nil)
        pendingTrack?.setOnDataAvailable(nil)
        pendingTrack = nil
        pendingPhase = nil
        layer.stopRequestingMediaData()
        if isTimebaseOwner {
            CMTimebaseSetRate(timebase, rate: 0)
        }
        timebaseStarted = !isTimebaseOwner
        enqueueQueue.async {
            self.pendingStallCheck?.cancel()
            self.pendingStallCheck = nil
            self.lastEnqueuedPTS = .invalid
            self.lastEnqueuedPTSus = 0
        }
    }

    /// Flushes the active track's jitter buffer and removes the displayed image.
    func flush() {
        activeTrack.flush()
        layer.flushAndRemoveImage()
        enqueueQueue.async {
            self.pendingStallCheck?.cancel()
            self.pendingStallCheck = nil
            self.lastEnqueuedPTS = .invalid
            self.lastEnqueuedPTSus = 0
        }
    }

    /// Installs a pending track. The drain loop's `SwapPhase` state machine will
    /// decide between a seamless cut-in and a flush-and-swap, then call `performSwap`.
    /// `onActivated` is called on `enqueueQueue` at the moment of the swap.
    func setPendingTrack(_ track: VideoRendererTrack, onActivated: @escaping () -> Void) {
        enqueueQueue.async {
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
        activeTrack.updateTargetBuffering(ms: ms)
    }

    var bufferFillMs: Double { enqueueQueue.sync { activeTrack.depthMs } }

    var hasPendingTrack: Bool { pendingTrack != nil }

    // MARK: - Private: drain loop

    private func armVideoEnqueue() {
        let queue = self.enqueueQueue
        let videoTimebase = self.timebase
        let isOwner = self.isTimebaseOwner
        let metricsRef = self.metrics

        var timebaseStarted = self.timebaseStarted

        layer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            let layer = self.layer

            // Start timebase once the active track has buffered enough depth (video-only mode).
            if isOwner && !timebaseStarted
                && self.activeTrack.state == JitterBuffer<VideoRendererSample>.State.playing
            {
                timebaseStarted = true
                self.timebaseStarted = true
                // Anchor the timebase to the first buffered frame's PTS so that
                // AVSampleBufferDisplayLayer schedules frames in the correct PTS domain.
                // Without this the timebase stays at 0 while frames have large live PTS
                // values, causing them to be scheduled far in the future and never display.
                if let firstPts = self.activeTrack.peekFront()?.timestampUs {
                    CMTimebaseSetTime(
                        videoTimebase,
                        time: CMTime(value: CMTimeValue(firstPts), timescale: 1_000_000))
                }
                CMTimebaseSetRate(videoTimebase, rate: 1.0)
            }

            while layer.isReadyForMoreMediaData {
                // --- Pending track swap state machine ---
                if let pending = self.pendingTrack, let phase = self.pendingPhase {
                    switch phase {
                    case .awaitingKeyframe:
                        // Drop stale non-keyframes that can never serve as a cut-in point.
                        while let front = pending.peekFront(),
                            !front.isKeyframe,
                            Int64(self.lastEnqueuedPTSus) - Int64(front.timestampUs)
                                > self.cutInWindowUs
                        {
                            pending.discardFront()
                        }
                        // Decide strategy once a keyframe is available.
                        if let kfPts = pending.firstKeyframePts {
                            let gap = Int64(self.lastEnqueuedPTSus) - Int64(kfPts)
                            if gap > self.flushThresholdUs {
                                self.pendingPhase = .flushAndSwap
                            } else {
                                self.pendingPhase = .cuttingIn(keyframePts: kfPts)
                            }
                        }
                    // else: no keyframe yet — data-available callback re-arms when one arrives.

                    case .cuttingIn(let kfPts):
                        // Drop any non-keyframe frames before the cut point so the pending
                        // front is the keyframe when we swap.
                        pending.discardNonKeyframesBeforePts(kfPts)
                        // Swap once the active track has reached the cut-in PTS.
                        if self.lastEnqueuedPTSus >= kfPts {
                            pending.setBufferState(.playing)
                            self.performSwap(to: pending)
                            self.pendingPhase = nil
                        }

                    case .flushAndSwap:
                        layer.flushAndRemoveImage()
                        pending.setBufferState(.playing)
                        self.performSwap(to: pending)
                        self.pendingPhase = nil
                    }
                }

                // --- Drain active track ---
                let (entry, playable) = self.activeTrack.dequeue()
                guard let entry else {
                    layer.stopRequestingMediaData()

                    // Emergency swap: active drained completely but pending has a keyframe.
                    if let pending = self.pendingTrack,
                        pending.peekFront()?.isKeyframe == true
                    {
                        pending.setBufferState(.playing)
                        self.performSwap(to: pending)
                        self.pendingPhase = nil
                        self.armVideoEnqueue()
                        return
                    }

                    // Otherwise: schedule a deferred stall check.
                    let currentTime = CMTimebaseGetTime(videoTimebase)
                    if self.lastEnqueuedPTS.isValid && currentTime < self.lastEnqueuedPTS {
                        let remaining = CMTimeSubtract(self.lastEnqueuedPTS, currentTime)
                        let delaySec = CMTimeGetSeconds(remaining)
                        let workItem = DispatchWorkItem { [weak self] in
                            self?.pendingStallCheck = nil
                            metricsRef.videoStallBegan()
                        }
                        self.pendingStallCheck = workItem
                        queue.asyncAfter(deadline: .now() + delaySec, execute: workItem)
                    } else {
                        metricsRef.videoStallBegan()
                    }
                    return
                }

                if !playable {
                    self.doNotDisplaySample(entry.item.sampleBuffer)
                    metricsRef.recordVideoFrameDropped()
                } else {
                    metricsRef.recordVideoFrameDisplayed()
                }
                layer.enqueue(entry.item.sampleBuffer)
                self.lastEnqueuedPTSus = entry.timestampUs
                self.lastEnqueuedPTS = CMTime(
                    value: CMTimeValue(entry.timestampUs),
                    timescale: 1_000_000)
            }
        }
    }

    /// Atomically promotes `newTrack` to active, fires `onTrackActivated`, and re-registers
    /// the data-available callback. Must be called on `enqueueQueue`.
    private func performSwap(to newTrack: VideoRendererTrack) {
        activeTrack.setOnDataAvailable(nil)
        activeTrack = newTrack
        pendingTrack = nil
        newTrack.setOnDataAvailable(makeDataAvailableCallback())
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
