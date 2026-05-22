import MoQKitFFI
import AVFoundation
import Atomics
import CoreMedia
import Foundation

// MARK: - AudioRenderer

/// Audio playback pipeline: ring buffer, AVAudioEngine, and external `AudioDrivenClock`.
///
/// Always acts as the master clock — the render callback drives the shared clock
/// by setting its time to the current ring buffer read position and toggling its rate
/// between 0 (underflow) and 1 (playing).
///
/// Thread safety: `enqueue(pcm:timestampUs:)` is called from the ingest task,
/// while the render callback reads from the audio thread. Both paths are serialized
/// via `os_unfair_lock`.
final class AudioRenderer: @unchecked Sendable {
    let clock: AudioDrivenClock

    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let ringState: RingState
    private let eventBridge: AudioRenderEventBridge
    private var volume: Float

    init(
        config: MoqAudio,
        clock: AudioDrivenClock,
        targetLatency: Duration,
        initialVolume: Float = 1.0,
        tracker: PlaybackStatsTracker
    ) throws {
        // Create a temporary decoder only to discover the output format for AVAudioEngine setup.
        let formatDecoder = try AudioDecoder(config: config)
        self.clock = clock
        self.volume = Self.clampedVolume(initialVolume)

        let channelCount = Int(config.channelCount)
        let sampleRate = Int(config.sampleRate)

        let ringState = RingState(
            rate: sampleRate, channels: channelCount, latency: targetLatency,
            tracker: tracker)
        self.ringState = ringState

        let bytesPerSample = MemoryLayout<Float32>.size
        var clockStarted = false

        // Pre-allocate read output buffers (resized per callback as needed)
        var readOutput: [[Float32]] = (0..<channelCount).map { _ in
            [Float32](repeating: 0, count: 1024)
        }

        let latencyProbe = AudioOutputLatencyProbe()
        let eventBridge = AudioRenderEventBridge(
            tracker: tracker,
            latencyProbe: latencyProbe
        )
        self.eventBridge = eventBridge
        let sourceNode = AVAudioSourceNode(format: formatDecoder.outputFormat) {
            _, timestamp, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let requestedFrames = Int(frameCount)

            // Ensure read output buffers are large enough
            if readOutput[0].count < requestedFrames {
                readOutput = (0..<channelCount).map { _ in
                    [Float32](repeating: 0, count: requestedFrames)
                }
            }

            // Read from ring buffer (thread-safe)
            let (framesRead, ts) = ringState.read(
                into: &readOutput, frameCount: requestedFrames)

            // Copy to audio buffer list and zero-fill any shortfall
            for (ch, buf) in ablPointer.enumerated() {
                guard let dst = buf.mData, ch < channelCount else { continue }
                readOutput[ch].withUnsafeBufferPointer { srcBuf in
                    dst.copyMemory(
                        from: UnsafeRawPointer(srcBuf.baseAddress!),
                        byteCount: framesRead * bytesPerSample)
                }
                if framesRead < requestedFrames {
                    (dst + framesRead * bytesPerSample).initializeMemory(
                        as: UInt8.self, repeating: 0,
                        count: (requestedFrames - framesRead) * bytesPerSample)
                }
            }

            if framesRead > 0 {
                clock.setTimeUs(ts)
                let hostTime =
                    timestamp.pointee.mHostTime > 0 ? timestamp.pointee.mHostTime : nil
                eventBridge.recordRenderedAudio(
                    timestampUs: ts,
                    hostTime: hostTime
                )

                // Start clock on first real audio data
                if !clockStarted {
                    clockStarted = true
                    clock.setRate(1.0)
                    eventBridge.recordStall(stalled: false)
                }
            } else {
                // Full underflow: pause clock to prevent drift
                if clockStarted {
                    clockStarted = false
                    clock.setRate(0)
                    eventBridge.recordStall(stalled: true)
                }
            }

            return noErr
        }
        sourceNode.volume = volume
        latencyProbe.sourceNode = sourceNode
        self.sourceNode = sourceNode

        // AVAudioEngine setup
        let engine = AVAudioEngine()
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: formatDecoder.outputFormat)
        engine.prepare()
        self.engine = engine

        KitLogger.player.debug(
            "AudioRenderer created, format = \(formatDecoder.outputFormat)")
    }

    /// Enqueue decoded PCM into the ring buffer. Thread-safe — called from the ingest task.
    func enqueue(pcm: AVAudioPCMBuffer, timestampUs: UInt64) {
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0, let channelData = pcm.floatChannelData else { return }
        ringState.decodeFrameSize = frameCount
        ringState.write(
            timestampUs: timestampUs, channelData: channelData, frameCount: frameCount)
    }

    func expectPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        eventBridge.expectPlaybackStart(
            trackName: trackName,
            sourceTimestampUs: sourceTimestampUs,
            targetBuffering: targetBuffering,
            trackEpoch: trackEpoch
        )
    }

    func start() throws {
        try engine.start()
        KitLogger.player.debug("AudioRenderer started")
    }

    func stop() {
        engine.stop()
        eventBridge.close()
        KitLogger.player.debug("AudioRenderer stopped")
    }

    func updateTargetLatency(_ latency: Duration) {
        ringState.resize(latency: latency)
    }

    func setVolume(_ volume: Float) {
        let clamped = Self.clampedVolume(volume)
        self.volume = clamped
        sourceNode.volume = clamped
    }

    func flush() {
        ringState.reset()
        eventBridge.clearExpectedPlaybackStart()
    }

    var bufferFill: Duration { .millisecondsClamped(ringState.fillMs) }

    private static func clampedVolume(_ volume: Float) -> Float {
        guard !volume.isNaN else { return 0 }
        return min(max(volume, 0), 1)
    }
}

private final class AudioOutputLatencyProbe: @unchecked Sendable {
    weak var sourceNode: AVAudioSourceNode?

    func outputPresentationLatency() -> Duration? {
        guard let sourceNode else { return nil }
        let latency = sourceNode.outputPresentationLatency
        guard latency.isFinite, latency >= 0 else { return nil }
        let nanoseconds = latency * 1_000_000_000
        guard nanoseconds < Double(Int64.max) else { return .nanoseconds(Int64.max) }
        return .nanoseconds(Int64(nanoseconds.rounded()))
    }
}

/// Moves telemetry emission out of the AVAudioSourceNode render callback.
///
/// The render callback only claims a pending first-audio-start context or reports a stall
/// transition. The actual tracker calls, listener fan-out, and AVAudio property reads run
/// on `queue`.
private final class AudioRenderEventBridge: @unchecked Sendable {
    private let tracker: PlaybackStatsTracker
    private let latencyProbe: AudioOutputLatencyProbe
    private let queue = DispatchQueue(
        label: "com.swmansion.MoQKit.AudioRenderEventBridge",
        qos: .utility
    )

    private let isClosed = ManagedAtomic<Bool>(false)

    init(
        tracker: PlaybackStatsTracker,
        latencyProbe: AudioOutputLatencyProbe
    ) {
        self.tracker = tracker
        self.latencyProbe = latencyProbe
    }

    deinit {
        close()
    }

    /// Arms the tracker to emit an audio first-frame playback-started event when the audio
    /// render callback observes a timestamp at or beyond `sourceTimestampUs`.
    func expectPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        guard !isClosed.load(ordering: .relaxed) else { return }
        tracker.expectAudioPlaybackStart(
            trackName: trackName,
            sourceTimestampUs: sourceTimestampUs,
            targetBuffering: targetBuffering,
            trackEpoch: trackEpoch
        )
    }

    func clearExpectedPlaybackStart() {
        tracker.clearExpectedAudioPlaybackStart()
    }

    func recordRenderedAudio(
        timestampUs: UInt64,
        hostTime: UInt64?
    ) {
        guard tracker.hasExpectedAudioPlaybackStart else { return }

        queue.async { [weak self] in
            guard let self, !self.isClosed.load(ordering: .relaxed) else { return }
            self.tracker.audioPlaybackStartedIfExpected(
                timestampUs: timestampUs,
                hostTime: hostTime,
                outputPresentationLatency: self.latencyProbe.outputPresentationLatency()
            )
        }
    }

    func recordStall(stalled: Bool) {
        guard !isClosed.load(ordering: .relaxed) else { return }
        queue.async { [weak self] in
            guard let self, !self.isClosed.load(ordering: .relaxed) else { return }
            stalled ? self.tracker.audioStallBegan() : self.tracker.audioStallEnded()
        }
    }

    func close() {
        guard !isClosed.exchange(true, ordering: .relaxed) else { return }
        clearExpectedPlaybackStart()
    }
}

// MARK: - RingState

/// Thread-safe wrapper around `AudioRingBuffer` using `os_unfair_lock`.
/// Shared between the ingest task (writes) and the audio render callback (reads).
private final class RingState: @unchecked Sendable {
    private var ringBuffer: AudioRingBuffer
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let tracker: PlaybackStatsTracker

    let channels: Int
    /// Approximate number of samples per decoded frame (set once from first decode).
    var decodeFrameSize: Int = 1024

    init(rate: Int, channels: Int, latency: Duration, tracker: PlaybackStatsTracker) {
        self.channels = channels
        self.tracker = tracker
        self.ringBuffer = AudioRingBuffer(
            rate: rate,
            channels: channels,
            latencyMs: latency.milliseconds
        )
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func write(
        timestampUs: UInt64,
        channelData: UnsafePointer<UnsafeMutablePointer<Float32>>,
        frameCount: Int
    ) {
        os_unfair_lock_lock(lock)
        let discarded = ringBuffer.write(
            timestampUs: timestampUs, channelData: channelData, frameCount: frameCount)
        os_unfair_lock_unlock(lock)

        if discarded > 0 {
            let droppedFrames = discarded / max(decodeFrameSize, 1)
            tracker.recordAudioFramesDropped(droppedFrames)
        }
    }

    func read(
        into output: inout [[Float32]], frameCount: Int
    ) -> (framesRead: Int, timestampUs: UInt64) {
        os_unfair_lock_lock(lock)
        let framesRead = ringBuffer.read(into: &output, frameCount: frameCount)
        let ts = ringBuffer.timestampUs
        os_unfair_lock_unlock(lock)
        return (framesRead, ts)
    }

    func resize(latency: Duration) {
        os_unfair_lock_lock(lock)
        ringBuffer.resize(latencyMs: latency.milliseconds)
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        ringBuffer.reset()
        os_unfair_lock_unlock(lock)
    }

    var fillMs: Double {
        os_unfair_lock_lock(lock)
        let v = ringBuffer.fillMs
        os_unfair_lock_unlock(lock)
        return v
    }
}
