import AVFoundation
import CoreMedia

// MARK: - VideoRenderer

/// Video playback pipeline: frame processor, jitter buffer, display layer interaction,
/// and optional timebase ownership for video-only mode.
///
/// Takes an external `CMTimebase`. When `isTimebaseOwner` is true (video-only mode),
/// the renderer starts the timebase once the jitter buffer reaches playing state.
/// When false (audio+video mode), the audio renderer drives the shared timebase.
///
/// Thread safety: `insert(...)` is called from the ingest task, while the
/// `requestMediaDataWhenReady` callback drains on `enqueueQueue`. The jitter buffer
/// serializes access via `os_unfair_lock`.
final class VideoRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase

    private let processor: VideoFrameProcessor
    private let jitterBuffer: JitterBuffer<CMSampleBuffer>
    private let enqueueQueue: DispatchQueue
    private let isTimebaseOwner: Bool
    private var timebaseStarted: Bool
    private let metrics: PlaybackMetricsAccumulator
    private var lastEnqueuedPTS: CMTime = .invalid
    private var pendingStallCheck: DispatchWorkItem?

    var canProcess: Bool { processor.canProcess }

    init(
        config: MoqVideo,
        timebase: CMTimebase,
        isTimebaseOwner: Bool,
        targetBufferingMs: UInt64,
        layer: AVSampleBufferDisplayLayer,
        metrics: PlaybackMetricsAccumulator
    ) throws {
        self.layer = layer
        self.timebase = timebase
        self.isTimebaseOwner = isTimebaseOwner
        self.metrics = metrics
        self.processor = try VideoFrameProcessor(config: config)
        self.jitterBuffer = JitterBuffer<CMSampleBuffer>(
            targetBufferingUs: targetBufferingMs * 1000)
        self.enqueueQueue = DispatchQueue(
            label: "com.moqkit.video-enqueue", qos: .userInteractive)

        layer.controlTimebase = timebase
        // If we don't own the timebase, assume it's already being driven (by audio)
        self.timebaseStarted = !isTimebaseOwner
    }

    /// Arms `requestMediaDataWhenReady` and registers the jitter buffer data-available callback.
    func start() {
        let jitter = self.jitterBuffer
        let queue = self.enqueueQueue
        let videoTimebase = self.timebase
        let isTimebaseOwner = self.isTimebaseOwner
        let metricsRef = self.metrics

        // Capture timebaseStarted as a mutable local for the closure (video-only mode)
        var timebaseStarted = self.timebaseStarted

        let armVideoEnqueue: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let layer = self.layer

            layer.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                let layer = self.layer

                // Start timebase once buffer has enough depth (video-only mode)
                if isTimebaseOwner && !timebaseStarted && jitter.state == .playing {
                    timebaseStarted = true
                    CMTimebaseSetRate(videoTimebase, rate: 1.0)
                }

                // Drain available frames
                while layer.isReadyForMoreMediaData {
                    let (entry, playable) = jitter.dequeue()
                    guard let entry else {
                        layer.stopRequestingMediaData()

                        // Check if the display layer still has frames to show
                        let currentTime = CMTimebaseGetTime(videoTimebase)
                        if self.lastEnqueuedPTS.isValid && currentTime < self.lastEnqueuedPTS {
                            // Layer still has frames — schedule a deferred stall check
                            let remaining = CMTimeSubtract(self.lastEnqueuedPTS, currentTime)
                            let delaySec = CMTimeGetSeconds(remaining)
                            let workItem = DispatchWorkItem { [weak self] in
                                self?.pendingStallCheck = nil
                                metricsRef.videoStallBegan()
                            }
                            self.pendingStallCheck = workItem
                            queue.asyncAfter(
                                deadline: .now() + delaySec, execute: workItem)
                        } else {
                            metricsRef.videoStallBegan()
                        }
                        return
                    }
                    if !playable {
                        self.doNotDisplaySample(entry.item)
                        metricsRef.recordVideoFrameDropped()
                    } else {
                        metricsRef.recordVideoFrameDisplayed()
                    }
                    layer.enqueue(entry.item)
                    self.lastEnqueuedPTS = CMTime(
                        value: CMTimeValue(entry.timestampUs),
                        timescale: 1_000_000)
                }
            }
        }

        jitter.setOnDataAvailable {
            queue.async {
                self.pendingStallCheck?.cancel()
                self.pendingStallCheck = nil
                metricsRef.videoStallEnded()
                armVideoEnqueue()
            }
        }

        queue.async { armVideoEnqueue() }

        MoQLogger.player.debug(
            "VideoRenderer started (isTimebaseOwner=\(isTimebaseOwner))")
    }

    /// Stops requesting media data, removes jitter buffer callback, pauses timebase if owned.
    func stop() {
        jitterBuffer.setOnDataAvailable(nil)
        layer.stopRequestingMediaData()
        if isTimebaseOwner {
            CMTimebaseSetRate(timebase, rate: 0)
        }
        timebaseStarted = !isTimebaseOwner
        enqueueQueue.async {
            self.pendingStallCheck?.cancel()
            self.pendingStallCheck = nil
            self.lastEnqueuedPTS = .invalid
        }
    }

    /// Flushes the jitter buffer and removes the displayed image.
    func flush() {
        jitterBuffer.flush()
        layer.flushAndRemoveImage()
        enqueueQueue.async {
            self.pendingStallCheck?.cancel()
            self.pendingStallCheck = nil
            self.lastEnqueuedPTS = .invalid
        }
    }

    /// Update the target buffering depth in milliseconds.
    func updateTargetBuffering(ms: UInt64) {
        jitterBuffer.updateTargetBuffering(us: ms * 1000)
    }

    /// Process and insert a video frame into the jitter buffer. Thread-safe.
    func insert(
        payload: Data, timestampUs: UInt64, keyframe: Bool
    ) throws -> Bool {
        guard
            let sb = try processor.process(
                payload: payload, timestampUs: timestampUs,
                keyframe: keyframe)
        else { return false }
        jitterBuffer.insert(item: sb, timestampUs: timestampUs)
        return true
    }
    
    private func doNotDisplaySample(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
            return
        }
        
        let dictPtr = CFArrayGetValueAtIndex(attachments, 0)
        let mutableDict = unsafeBitCast(dictPtr, to: CFMutableDictionary.self)
        
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque()
        let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        
        CFDictionarySetValue(mutableDict, key, value)
    }
}

