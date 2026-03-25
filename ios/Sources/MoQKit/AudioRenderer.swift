#if os(iOS)
    import AVFoundation
    import CoreMedia

    // MARK: - AudioRenderer

    /// Audio playback pipeline: ring buffer, AVAudioEngine, and external CMTimebase.
    ///
    /// Always acts as the master clock — the render callback drives the shared timebase
    /// by setting its time to the current ring buffer read position and toggling its rate
    /// between 0 (underflow) and 1 (playing).
    ///
    /// Thread safety: `enqueue(pcm:timestampUs:)` is called from the ingest task,
    /// while the render callback reads from the audio thread. Both paths are serialized
    /// via `os_unfair_lock`.
    final class AudioRenderer: @unchecked Sendable {
        let timebase: CMTimebase
        let decoder: AudioDecoder

        private let engine: AVAudioEngine
        private let sourceNode: AVAudioSourceNode
        private let ringState: RingState
        private let metrics: PlaybackMetricsAccumulator

        init(
            config: MoqAudio,
            timebase: CMTimebase,
            targetLatencyMs: Int,
            metrics: PlaybackMetricsAccumulator
        ) throws {
            let decoder = try AudioDecoder(config: config)
            self.decoder = decoder
            self.timebase = timebase
            self.metrics = metrics

            let channelCount = Int(config.channelCount)
            let sampleRate = Int(config.sampleRate)

            let ringState = RingState(
                rate: sampleRate, channels: channelCount, latencyMs: Double(targetLatencyMs),
                metrics: metrics)
            self.ringState = ringState

            let bytesPerSample = MemoryLayout<Float32>.size
            var timebaseStarted = false

            // Pre-allocate read output buffers (resized per callback as needed)
            var readOutput: [[Float32]] = (0..<channelCount).map { _ in
                [Float32](repeating: 0, count: 1024)
            }

            let metricsRef = metrics
            let sourceNode = AVAudioSourceNode(format: decoder.outputFormat) {
                _, _, frameCount, audioBufferList -> OSStatus in
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
                    CMTimebaseSetTime(
                        timebase,
                        time: CMTime(
                            value: CMTimeValue(ts), timescale: 1_000_000)
                    )

                    // Start timebase on first real audio data
                    if !timebaseStarted {
                        timebaseStarted = true
                        CMTimebaseSetRate(timebase, rate: 1.0)
                        metricsRef.audioStallEnded()
                    }
                } else {
                    // Full underflow: pause timebase to prevent drift
                    if timebaseStarted {
                        timebaseStarted = false
                        CMTimebaseSetRate(timebase, rate: 0)
                        metricsRef.audioStallBegan()
                    }
                }

                return noErr
            }
            self.sourceNode = sourceNode

            // AVAudioEngine setup
            let engine = AVAudioEngine()
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: decoder.outputFormat)
            engine.prepare()
            self.engine = engine

            MoQLogger.player.debug(
                "AudioRenderer created, format = \(decoder.outputFormat)")
        }

        /// Enqueue decoded PCM into the ring buffer. Thread-safe — called from the ingest task.
        func enqueue(pcm: AVAudioPCMBuffer, timestampUs: UInt64) {
            let frameCount = Int(pcm.frameLength)
            guard frameCount > 0, let channelData = pcm.floatChannelData else { return }
            ringState.decodeFrameSize = frameCount
            ringState.write(
                timestampUs: timestampUs, channelData: channelData, frameCount: frameCount)
        }

        func start() throws {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback)
            try audioSession.setActive(true)
            try engine.start()
            MoQLogger.player.debug("AudioRenderer started")
        }

        func stop() {
            engine.stop()
            MoQLogger.player.debug("AudioRenderer stopped")
        }

        func updateTargetLatency(ms: Int) {
            ringState.resize(latencyMs: Double(ms))
        }

        func flush() {
            ringState.reset()
        }

        var bufferFillMs: Double { ringState.fillMs }
    }

    // MARK: - RingState

    /// Thread-safe wrapper around `AudioRingBuffer` using `os_unfair_lock`.
    /// Shared between the ingest task (writes) and the audio render callback (reads).
    private final class RingState: @unchecked Sendable {
        private var ringBuffer: AudioRingBuffer
        private let lock: UnsafeMutablePointer<os_unfair_lock>
        private let metrics: PlaybackMetricsAccumulator

        let channels: Int
        /// Approximate number of samples per decoded frame (set once from first decode).
        var decodeFrameSize: Int = 1024

        init(rate: Int, channels: Int, latencyMs: Double, metrics: PlaybackMetricsAccumulator) {
            self.channels = channels
            self.metrics = metrics
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
                metrics.recordAudioFramesDropped(droppedFrames)
            }
        }

        func read(
            into output: inout [[Float32]], frameCount: Int
        ) -> (framesRead: Int, timestampUs: UInt64) {
            os_unfair_lock_lock(lock)
            let framesRead = ringBuffer.read(into: &output)
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

#endif
