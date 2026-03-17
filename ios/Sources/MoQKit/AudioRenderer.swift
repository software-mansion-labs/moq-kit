#if os(iOS)
    import AVFoundation
    import CoreMedia

    // MARK: - AudioRenderer

    /// Owns the full audio playback pipeline: ring buffer, AVAudioEngine, and CMTimebase.
    ///
    /// The ring buffer handles timestamp-based positioning, stall management, gap filling,
    /// and overflow — replacing the need for a separate jitter buffer.
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

        init(
            config: MoqAudio,
            latencyMs: Int
        ) throws {
            let decoder = try AudioDecoder(config: config)
            self.decoder = decoder

            let channelCount = Int(config.channelCount)
            let sampleRate = Int(config.sampleRate)

            let ringState = RingState(
                rate: sampleRate, channels: channelCount, latencyMs: Double(latencyMs))
            self.ringState = ringState

            // CMTimebase sourced from host clock, rate=0 initially
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &tb
            )
            guard let timebase = tb else {
                throw MoQSessionError.audioDecoderFailed("Failed to create CMTimebase")
            }
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
            self.timebase = timebase

            let bytesPerSample = MemoryLayout<Float32>.size
            var timebaseStarted = false

            // Pre-allocate read output buffers (resized per callback as needed)
            var readOutput: [[Float32]] = (0..<channelCount).map { _ in
                [Float32](repeating: 0, count: 1024)
            }

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
                    }
                } else {
                    // Full underflow: pause timebase to prevent drift
                    if timebaseStarted {
                        timebaseStarted = false
                        CMTimebaseSetRate(timebase, rate: 0)
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
            guard frameCount > 0 else { return }

            var channelData: [[Float32]] = []
            for ch in 0..<ringState.channels {
                if let src = pcm.floatChannelData?[ch] {
                    channelData.append(
                        Array(UnsafeBufferPointer(start: src, count: frameCount)))
                }
            }

            ringState.write(timestampUs: timestampUs, data: channelData)
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

        func flush() {
            ringState.reset()
        }
    }

    // MARK: - RingState

    /// Thread-safe wrapper around `AudioRingBuffer` using `os_unfair_lock`.
    /// Shared between the ingest task (writes) and the audio render callback (reads).
    private final class RingState: @unchecked Sendable {
        private var ringBuffer: AudioRingBuffer
        private let lock: UnsafeMutablePointer<os_unfair_lock>

        let channels: Int

        init(rate: Int, channels: Int, latencyMs: Double) {
            self.channels = channels
            self.ringBuffer = AudioRingBuffer(rate: rate, channels: channels, latencyMs: latencyMs)
            self.lock = .allocate(capacity: 1)
            self.lock.initialize(to: os_unfair_lock())
        }

        deinit {
            lock.deinitialize(count: 1)
            lock.deallocate()
        }

        func write(timestampUs: UInt64, data: [[Float32]]) {
            os_unfair_lock_lock(lock)
            ringBuffer.write(timestampUs: timestampUs, data: data)
            os_unfair_lock_unlock(lock)
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

        func reset() {
            os_unfair_lock_lock(lock)
            ringBuffer.reset()
            os_unfair_lock_unlock(lock)
        }
    }

#endif
