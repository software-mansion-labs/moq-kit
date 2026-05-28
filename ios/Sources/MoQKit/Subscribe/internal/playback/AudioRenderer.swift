import MoqFFI
import AVFoundation
import Atomics
import CoreMedia
import Foundation

// MARK: - AudioRenderer

protocol AudioRendererDelegate: AnyObject, Sendable {
    func audioRendererHasPendingPlaybackStart(_ renderer: AudioRenderer) -> Bool
    func audioRenderer(_ renderer: AudioRenderer, didPreparePlaybackStart context: PlaybackStartContext)
    func audioRendererDidClearExpectedPlaybackStart(_ renderer: AudioRenderer)
    func audioRenderer(
        _ renderer: AudioRenderer,
        didRenderAudioAt timestampUs: UInt64,
        hostTime: UInt64?
    )
    func audioRendererDidBeginStall(_ renderer: AudioRenderer)
    func audioRendererDidEndStall(_ renderer: AudioRenderer)
    func audioRenderer(_ renderer: AudioRenderer, didDropFrames count: Int)
}

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
    private weak var delegate: (any AudioRendererDelegate)?
    private var volume: Float

    init(
        config: MoqAudio,
        clock: AudioDrivenClock,
        targetLatency: Duration,
        initialVolume: Float = 1.0,
        delegate: any AudioRendererDelegate
    ) throws {
        // Create a temporary decoder only to discover the output format for AVAudioEngine setup.
        let formatDecoder = try AudioDecoder(config: config)
        self.clock = clock
        self.volume = Self.clampedVolume(initialVolume)
        self.delegate = delegate

        let channelCount = Int(config.channelCount)
        let sampleRate = Int(config.sampleRate)

        let ringState = RingState(
            rate: sampleRate, channels: channelCount, latency: targetLatency)
        self.ringState = ringState

        let bytesPerSample = MemoryLayout<Float32>.size
        var clockStarted = false

        // Pre-allocate read output buffers (resized per callback as needed)
        var readOutput: [[Float32]] = (0..<channelCount).map { _ in
            [Float32](repeating: 0, count: 1024)
        }

        let eventBridge = AudioRenderEventBridge(
            delegate: delegate
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
        self.sourceNode = sourceNode

        // AVAudioEngine setup
        let engine = AVAudioEngine()
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: formatDecoder.outputFormat)
        engine.prepare()
        self.engine = engine
        eventBridge.renderer = self

        KitLogger.player.debug(
            "AudioRenderer created, format = \(formatDecoder.outputFormat)")
    }

    /// Enqueue decoded PCM into the ring buffer. Thread-safe — called from the ingest task.
    func enqueue(pcm: AVAudioPCMBuffer, timestampUs: UInt64) {
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0, let channelData = pcm.floatChannelData else { return }
        ringState.decodeFrameSize = frameCount
        let droppedFrames = ringState.write(
            timestampUs: timestampUs, channelData: channelData, frameCount: frameCount)
        if droppedFrames > 0 {
            delegate?.audioRenderer(self, didDropFrames: droppedFrames)
        }
    }

    func expectPlaybackStart(
        trackName: String,
        sourceTimestampUs: UInt64,
        targetBuffering: Duration,
        trackEpoch: TrackEpoch
    ) {
        eventBridge.expectPlaybackStart(
            PlaybackStartContext(
                kind: .audio,
                trackName: trackName,
                sourceTimestampUs: sourceTimestampUs,
                targetBuffering: targetBuffering,
                trackEpoch: trackEpoch
            )
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

/// Moves render event emission out of the AVAudioSourceNode render callback.
///
/// The render callback only claims a pending first-audio-start context or reports a stall
/// transition. Delegate callbacks, listener fan-out, and AVAudio property reads run
/// on `queue`.
private final class AudioRenderEventBridge: @unchecked Sendable {
    private weak var delegate: (any AudioRendererDelegate)?
    weak var renderer: AudioRenderer?

    private let queue = DispatchQueue(
        label: "com.swmansion.MoQKit.AudioRenderEventBridge",
        qos: .utility
    )

    private let isClosed = ManagedAtomic<Bool>(false)

    init(delegate: any AudioRendererDelegate) {
        self.delegate = delegate
    }

    deinit {
        close()
    }

    /// Arms the delegate to emit an audio first-frame playback-started event when the audio
    /// render callback observes a timestamp at or beyond `sourceTimestampUs`.
    func expectPlaybackStart(_ context: PlaybackStartContext) {
        guard !isClosed.load(ordering: .relaxed), let renderer else { return }
        delegate?.audioRenderer(renderer, didPreparePlaybackStart: context)
    }

    func clearExpectedPlaybackStart() {
        guard let renderer else { return }
        delegate?.audioRendererDidClearExpectedPlaybackStart(renderer)
    }

    func recordRenderedAudio(
        timestampUs: UInt64,
        hostTime: UInt64?
    ) {
        guard let renderer,
              delegate?.audioRendererHasPendingPlaybackStart(renderer) == true
        else { return }

        queue.async { [weak self] in
            guard let self,
                  let renderer = self.renderer,
                  !self.isClosed.load(ordering: .relaxed)
            else { return }
            self.delegate?.audioRenderer(
                renderer,
                didRenderAudioAt: timestampUs,
                hostTime: hostTime
            )
        }
    }

    func recordStall(stalled: Bool) {
        guard !isClosed.load(ordering: .relaxed) else { return }
        queue.async { [weak self] in
            guard let self,
                  let renderer = self.renderer,
                  !self.isClosed.load(ordering: .relaxed)
            else { return }
            stalled
                ? self.delegate?.audioRendererDidBeginStall(renderer)
                : self.delegate?.audioRendererDidEndStall(renderer)
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

    let channels: Int
    /// Approximate number of samples per decoded frame (set once from first decode).
    var decodeFrameSize: Int = 1024

    init(rate: Int, channels: Int, latency: Duration) {
        self.channels = channels
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
    ) -> Int {
        os_unfair_lock_lock(lock)
        let discarded = ringBuffer.write(
            timestampUs: timestampUs, channelData: channelData, frameCount: frameCount)
        os_unfair_lock_unlock(lock)

        return discarded / max(decodeFrameSize, 1)
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
