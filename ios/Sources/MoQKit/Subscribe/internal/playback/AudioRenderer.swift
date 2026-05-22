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
    private let renderEvents: AudioRenderEventBridge
    private var volume: Float

    init(
        config: MoqAudio,
        clock: AudioDrivenClock,
        targetLatencyMs: Int,
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
            rate: sampleRate, channels: channelCount, latencyMs: Double(targetLatencyMs),
            tracker: tracker)
        self.ringState = ringState

        let bytesPerSample = MemoryLayout<Float32>.size
        var clockStarted = false

        // Pre-allocate read output buffers (resized per callback as needed)
        var readOutput: [[Float32]] = (0..<channelCount).map { _ in
            [Float32](repeating: 0, count: 1024)
        }

        let latencyProbe = AudioOutputLatencyProbe()
        let renderEvents = AudioRenderEventBridge(
            tracker: tracker,
            latencyProbe: latencyProbe
        )
        self.renderEvents = renderEvents
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
                let outputHostTime =
                    timestamp.pointee.mHostTime > 0 ? timestamp.pointee.mHostTime : nil
                renderEvents.recordRenderedAudio(
                    renderedTimestampUs: ts,
                    outputHostTime: outputHostTime
                )

                // Start clock on first real audio data
                if !clockStarted {
                    clockStarted = true
                    clock.setRate(1.0)
                    renderEvents.recordStallState(isStalled: false)
                }
            } else {
                // Full underflow: pause clock to prevent drift
                if clockStarted {
                    clockStarted = false
                    clock.setRate(0)
                    renderEvents.recordStallState(isStalled: true)
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
        targetBufferingMs: UInt64,
        trackEpoch: UInt64
    ) {
        renderEvents.expectPlaybackStart(
            trackName: trackName,
            sourceTimestampUs: sourceTimestampUs,
            targetBufferingMs: targetBufferingMs,
            trackEpoch: trackEpoch
        )
    }

    func start() throws {
        try engine.start()
        KitLogger.player.debug("AudioRenderer started")
    }

    func stop() {
        engine.stop()
        renderEvents.close()
        KitLogger.player.debug("AudioRenderer stopped")
    }

    func updateTargetLatency(ms: Int) {
        ringState.resize(latencyMs: Double(ms))
    }

    func setVolume(_ volume: Float) {
        let clamped = Self.clampedVolume(volume)
        self.volume = clamped
        sourceNode.volume = clamped
    }

    func flush() {
        ringState.reset()
        renderEvents.clearExpectedPlaybackStart()
    }

    var bufferFillMs: Double { ringState.fillMs }

    private static func clampedVolume(_ volume: Float) -> Float {
        guard !volume.isNaN else { return 0 }
        return min(max(volume, 0), 1)
    }
}

private struct AudioPlaybackStartedRender {
    let renderedTimestampUs: UInt64
    let outputHostTime: UInt64?
}

private final class AudioOutputLatencyProbe: @unchecked Sendable {
    weak var sourceNode: AVAudioSourceNode?

    func outputPresentationLatencyMs() -> Double? {
        guard let sourceNode else { return nil }
        let latency = sourceNode.outputPresentationLatency
        guard latency.isFinite, latency >= 0 else { return nil }
        return latency * 1000
    }
}

/// Moves telemetry emission out of the AVAudioSourceNode render callback.
///
/// The render callback only records primitive state under a tiny lock. A timer on a normal
/// Dispatch queue drains that state and calls into `PlaybackStatsTracker`, where events,
/// listener fan-out, and AVAudio property reads are allowed.
private final class AudioRenderEventBridge: @unchecked Sendable {
    private let tracker: PlaybackStatsTracker
    private let latencyProbe: AudioOutputLatencyProbe
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let timer: DispatchSourceTimer

    private var pendingPlaybackStart: PlaybackStartContext?
    private var playbackStartedRender: AudioPlaybackStartedRender?
    private var pendingStallTransitions: [Bool] = []
    private var isClosed = false

    /// Fast-path probes consulted lock-free from the render thread (`recordRenderedAudio`)
    /// and the drain timer. Mutated only while `lock` is held.
    private let hasPendingPlaybackStart = ManagedAtomic<Bool>(false)
    private let hasPendingStallTransition = ManagedAtomic<Bool>(false)

    init(
        tracker: PlaybackStatsTracker,
        latencyProbe: AudioOutputLatencyProbe
    ) {
        self.tracker = tracker
        self.latencyProbe = latencyProbe
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())

        let queue = DispatchQueue(label: "com.swmansion.MoQKit.AudioRenderEvents", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        timer.resume()
    }

    deinit {
        close()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Arms the bridge to emit an audio first-frame playback-started event when the audio
    /// render callback observes a rendered timestamp at or beyond `sourceTimestampUs`.
    ///
    /// The `renderedTimestampUs` and `outputHostTime` measurements are captured precisely
    /// on the audio render thread inside `recordRenderedAudio`. The *event emission* is
    /// deferred up to ~25 ms (one drain-timer tick) so that locks, Obj-C calls, and listener
    /// fan-out stay off the realtime audio thread. Consumers using `renderedTimestampUs` as
    /// a precise wall-clock anchor are unaffected; consumers using the event's own
    /// `timestampMs` for TTFF gain a bounded skew of ≤25 ms relative to the actual
    /// first-rendered moment.
    func expectPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBufferingMs: UInt64,
        trackEpoch: UInt64
    ) {
        os_unfair_lock_lock(lock)
        guard !isClosed else {
            os_unfair_lock_unlock(lock)
            return
        }
        pendingPlaybackStart = PlaybackStartContext(
            kind: .audio,
            trackName: trackName,
            sourceTimestampUs: sourceTimestampUs,
            targetBufferingMs: targetBufferingMs,
            trackEpoch: trackEpoch
        )
        playbackStartedRender = nil
        hasPendingPlaybackStart.store(true, ordering: .relaxed)
        os_unfair_lock_unlock(lock)
    }

    func clearExpectedPlaybackStart() {
        os_unfair_lock_lock(lock)
        pendingPlaybackStart = nil
        playbackStartedRender = nil
        hasPendingPlaybackStart.store(false, ordering: .relaxed)
        os_unfair_lock_unlock(lock)
    }

    func recordRenderedAudio(
        renderedTimestampUs: UInt64,
        outputHostTime: UInt64?
    ) {
        guard hasPendingPlaybackStart.load(ordering: .relaxed) else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard !isClosed,
              playbackStartedRender == nil,
              let sourceTimestampUs = pendingPlaybackStart?.sourceTimestampUs,
              renderedTimestampUs >= sourceTimestampUs
        else { return }

        playbackStartedRender = AudioPlaybackStartedRender(
            renderedTimestampUs: renderedTimestampUs,
            outputHostTime: outputHostTime
        )
        hasPendingPlaybackStart.store(false, ordering: .relaxed)
    }

    func recordStallState(isStalled: Bool) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard !isClosed else { return }
        pendingStallTransitions.append(isStalled)
        hasPendingStallTransition.store(true, ordering: .relaxed)
    }

    func close() {
        let shouldDrain: Bool
        os_unfair_lock_lock(lock)
        shouldDrain = !isClosed
        isClosed = true
        hasPendingPlaybackStart.store(false, ordering: .relaxed)
        os_unfair_lock_unlock(lock)

        guard shouldDrain else { return }
        drain()
        timer.cancel()
    }

    private func drain() {
        if !hasPendingPlaybackStart.load(ordering: .relaxed),
           !hasPendingStallTransition.load(ordering: .relaxed) {
            return
        }

        let snapshot = takeSnapshot()

        for isStalled in snapshot.stallTransitions {
            if isStalled {
                tracker.audioStallBegan()
            } else {
                tracker.audioStallEnded()
            }
        }

        if let playbackStart = snapshot.playbackStart {
            tracker.audioPlaybackStarted(
                context: playbackStart.context,
                renderedTimestampUs: playbackStart.render.renderedTimestampUs,
                outputHostTime: playbackStart.render.outputHostTime,
                outputPresentationLatencyMs: latencyProbe.outputPresentationLatencyMs()
            )
        }
    }

    private func takeSnapshot()
        -> (
            playbackStart: (context: PlaybackStartContext, render: AudioPlaybackStartedRender)?,
            stallTransitions: [Bool]
        )
    {
        os_unfair_lock_lock(lock)

        let playbackStart: (PlaybackStartContext, AudioPlaybackStartedRender)?
        if let context = pendingPlaybackStart, let render = playbackStartedRender {
            playbackStart = (context, render)
            pendingPlaybackStart = nil
            playbackStartedRender = nil
        } else {
            playbackStart = nil
        }

        let stallTransitions = pendingStallTransitions
        pendingStallTransitions.removeAll(keepingCapacity: true)
        hasPendingStallTransition.store(false, ordering: .relaxed)

        os_unfair_lock_unlock(lock)
        return (playbackStart, stallTransitions)
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

    init(rate: Int, channels: Int, latencyMs: Double, tracker: PlaybackStatsTracker) {
        self.channels = channels
        self.tracker = tracker
        self.ringBuffer = AudioRingBuffer(rate: rate, channels: channels, latencyMs: latencyMs)
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

    func resize(latencyMs: Double) {
        os_unfair_lock_lock(lock)
        ringBuffer.resize(latencyMs: latencyMs)
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
