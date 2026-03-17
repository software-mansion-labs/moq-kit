import AVFoundation
import CoreMedia

// MARK: - VideoRenderer

/// Owns the full video playback pipeline: frame processor, jitter buffer, display layer interaction,
/// and timebase management for video-only mode.
///
/// Thread safety: `insert(...)` is called from the ingest task, while the
/// `requestMediaDataWhenReady` callback drains on `enqueueQueue`. The jitter buffer
/// serializes access via `os_unfair_lock`.
final class VideoRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase

    private let processor: VideoFrameProcessor
    private let jitterBuffer: JitterBuffer<CMSampleBuffer>
    private let tracer: PacketTimingTracer
    private let enqueueQueue: DispatchQueue
    private let ownsTimebase: Bool
    private var timebaseStarted: Bool

    var canProcess: Bool { processor.canProcess }

    init(
        config: MoqVideo,
        externalTimebase: CMTimebase?,
        targetBufferingMs: UInt64,
        layer: AVSampleBufferDisplayLayer,
        tracer: PacketTimingTracer
    ) throws {
        self.layer = layer
        self.processor = try VideoFrameProcessor(config: config)
        self.jitterBuffer = JitterBuffer<CMSampleBuffer>(
            targetBufferingUs: targetBufferingMs * 1000)
        self.tracer = tracer
        self.enqueueQueue = DispatchQueue(
            label: "com.moqkit.video-enqueue", qos: .userInteractive)

        if let ext = externalTimebase {
            self.timebase = ext
            layer.controlTimebase = ext
            self.ownsTimebase = false
            self.timebaseStarted = true
        } else {
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &tb
            )
            guard let tb else {
                throw MoQSessionError.invalidConfiguration(
                    "Failed to create CMTimebase")
            }
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            self.timebase = tb
            layer.controlTimebase = tb
            self.ownsTimebase = true
            self.timebaseStarted = false
        }
    }

    /// Arms `requestMediaDataWhenReady` and registers the jitter buffer data-available callback.
    func start() {
        let layer = self.layer
        let jitter = self.jitterBuffer
        let queue = self.enqueueQueue
        let tracer = self.tracer
        let videoTimebase = self.timebase
        let ownsTimebase = self.ownsTimebase

        // Capture timebaseStarted as a mutable local for the closure (video-only mode)
        var timebaseStarted = self.timebaseStarted

        let armVideoEnqueue: @Sendable () -> Void = { [weak layer] in
            guard let layer else { return }

            layer.requestMediaDataWhenReady(on: queue) { [weak layer] in
                guard let layer else { return }

                // Start timebase once buffer has enough depth (video-only mode)
                if ownsTimebase && !timebaseStarted && jitter.state == .playing {
                    timebaseStarted = true
                    CMTimebaseSetRate(videoTimebase, rate: 1.0)
                }

                // Drain available frames
                while layer.isReadyForMoreMediaData {
                    let (entry, playable) = jitter.dequeue()
                    guard let entry else {
                        layer.stopRequestingMediaData()
                        return
                    }
                    if !playable { continue }  // drop late frames
                    tracer.record(ptsUs: entry.timestampUs)
                    layer.enqueue(entry.item)
                }
            }
        }

        jitter.setOnDataAvailable {
            queue.async { armVideoEnqueue() }
        }

        queue.async { armVideoEnqueue() }

        MoQLogger.player.debug(
            "VideoRenderer started (ownsTimebase=\(ownsTimebase))")
    }

    /// Stops requesting media data, removes jitter buffer callback, pauses timebase if owned.
    func stop() {
        jitterBuffer.setOnDataAvailable(nil)
        layer.stopRequestingMediaData()
        if ownsTimebase {
            CMTimebaseSetRate(timebase, rate: 0)
        }
        timebaseStarted = !ownsTimebase
    }

    /// Flushes the jitter buffer and removes the displayed image.
    func flush() {
        jitterBuffer.flush()
        layer.flushAndRemoveImage()
    }

    /// Resets the packet timing tracer.
    func resetTracer() {
        tracer.reset()
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
        tracer.record(ptsUs: timestampUs)
        jitterBuffer.insert(item: sb, timestampUs: timestampUs)
        return true
    }
}

