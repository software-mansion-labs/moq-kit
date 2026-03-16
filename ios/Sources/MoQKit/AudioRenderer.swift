#if os(iOS)
    import AVFoundation
    import CoreMedia

    // MARK: - PCMRingBuffer

    /// Lock-free circular buffer for Float32 PCM samples (non-interleaved, per-channel).
    /// Only accessed from the AVAudioSourceNode render callback (single thread).
    struct PCMRingBuffer {
        private let capacity: Int
        private let channelCount: Int
        private var buffers: [[Float32]]
        private var readIndex: Int = 0
        private var writeIndex: Int = 0
        private var availableFrames: Int = 0
        private var lastTimestampUs: UInt64?

        init(capacity: Int, channelCount: Int) {
            self.capacity = capacity
            self.channelCount = channelCount
            self.buffers = (0..<channelCount).map { _ in [Float32](repeating: 0, count: capacity) }
        }

        /// Append decoded PCM frames into the ring buffer, tracking the timestamp.
        mutating func write(from pcm: AVAudioPCMBuffer, timestampUs: UInt64) {
            let frameCount = Int(pcm.frameLength)
            guard frameCount > 0 else { return }

            let framesToWrite = min(frameCount, capacity - availableFrames)
            guard framesToWrite > 0 else { return }

            for ch in 0..<channelCount {
                guard let src = pcm.floatChannelData?[ch] else { continue }
                var remaining = framesToWrite
                var srcOffset = 0
                var dst = writeIndex

                while remaining > 0 {
                    let chunk = min(remaining, capacity - dst)
                    buffers[ch].withUnsafeMutableBufferPointer { buf in
                        buf.baseAddress!.advanced(by: dst)
                            .update(from: src.advanced(by: srcOffset), count: chunk)
                    }
                    remaining -= chunk
                    srcOffset += chunk
                    dst = (dst + chunk) % capacity
                }
            }

            writeIndex = (writeIndex + framesToWrite) % capacity
            availableFrames += framesToWrite
            lastTimestampUs = timestampUs
        }

        /// Read exactly `frameCount` frames into the audio buffer list.
        /// Returns how many frames were actually read and the timestamp of the last written data.
        mutating func read(
            into ablPointer: UnsafeMutableAudioBufferListPointer,
            frameCount: Int
        ) -> (framesRead: Int, lastTimestampUs: UInt64?) {
            let framesToRead = min(frameCount, availableFrames)
            guard framesToRead > 0 else { return (0, lastTimestampUs) }

            let bytesPerSample = MemoryLayout<Float32>.size

            for (ch, buf) in ablPointer.enumerated() {
                guard let dst = buf.mData, ch < channelCount else { continue }
                var remaining = framesToRead
                var dstOffset = 0
                var src = readIndex

                while remaining > 0 {
                    let chunk = min(remaining, capacity - src)
                    buffers[ch].withUnsafeBufferPointer { srcBuf in
                        dst.advanced(by: dstOffset * bytesPerSample)
                            .copyMemory(
                                from: UnsafeRawPointer(srcBuf.baseAddress!.advanced(by: src)),
                                byteCount: chunk * bytesPerSample
                            )
                    }
                    remaining -= chunk
                    dstOffset += chunk
                    src = (src + chunk) % capacity
                }
            }

            readIndex = (readIndex + framesToRead) % capacity
            availableFrames -= framesToRead
            return (framesToRead, lastTimestampUs)
        }

        var count: Int { availableFrames }

        mutating func flush() {
            readIndex = 0
            writeIndex = 0
            availableFrames = 0
            lastTimestampUs = nil
        }
    }

    // MARK: - AudioRenderer

    /// Owns the full audio playback pipeline: decoder, jitter buffer, PCM ring buffer,
    /// AVAudioEngine, and CMTimebase. Fixes frame-count mismatches and timebase drift.
    final class AudioRenderer: @unchecked Sendable {
        let jitterBuffer: JitterBuffer<AVAudioPCMBuffer>
        let timebase: CMTimebase

        let decoder: AudioDecoder
        private let engine: AVAudioEngine
        private let sourceNode: AVAudioSourceNode
        private let latencyTracker: LatencyTracker
        private let sharedBaseTs: BaseTimestamp

        init(
            config: MoqAudio,
            targetBufferingUs: UInt64,
            sharedBaseTs: BaseTimestamp,
            latencyTracker: LatencyTracker
        ) throws {
            self.sharedBaseTs = sharedBaseTs
            self.latencyTracker = latencyTracker

            let decoder = try AudioDecoder(config: config)
            self.decoder = decoder

            let jitter = JitterBuffer<AVAudioPCMBuffer>(targetBufferingUs: targetBufferingUs)
            self.jitterBuffer = jitter

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

            // Ring buffer: ~170ms at 48kHz, enough for several decoded packets
            let ringCapacity = 8192
            let channelCount = Int(config.channelCount)

            // Mutable state captured by the render callback
            var ringBuffer = PCMRingBuffer(capacity: ringCapacity, channelCount: channelCount)
            var timebaseStarted = false
            let bytesPerSample = MemoryLayout<Float32>.size

            let sourceNode = AVAudioSourceNode(format: decoder.outputFormat) {
                _, _, frameCount, audioBufferList -> OSStatus in
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let requestedFrames = Int(frameCount)

                // Fill ring buffer from jitter buffer until we have enough frames (or underflow)
                while ringBuffer.count < requestedFrames {
                    guard let entry = jitter.dequeue() else { break }
                    latencyTracker.record(ptsUs: entry.timestampUs)
                    ringBuffer.write(from: entry.item, timestampUs: entry.timestampUs)
                }

                // Read exactly requestedFrames from ring buffer
                let (framesRead, lastTs) = ringBuffer.read(
                    into: ablPointer, frameCount: requestedFrames)

                // Zero-fill any shortfall (underflow)
                if framesRead < requestedFrames {
                    let offset = framesRead * bytesPerSample
                    let zeroCount = (requestedFrames - framesRead) * bytesPerSample
                    for buf in ablPointer {
                        guard let dst = buf.mData else { continue }
                        (dst + offset).initializeMemory(
                            as: UInt8.self, repeating: 0, count: zeroCount)
                    }
                }

                if framesRead > 0 {
                    // Update timebase from the latest consumed timestamp
                    if let ts = lastTs {
                        let baseUs = sharedBaseTs.resolve(ts)
                        let relativeUs = ts >= baseUs ? ts - baseUs : 0
                        CMTimebaseSetTime(
                            timebase,
                            time: CMTime(
                                value: CMTimeValue(relativeUs), timescale: 1_000_000)
                        )
                    }

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

        func start() throws {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback)
            try audioSession.setActive(true)
            try engine.start()
            MoQLogger.player.debug("AudioRenderer started")
        }

        func stop() {
            engine.stop()
            jitterBuffer.flush()
            MoQLogger.player.debug("AudioRenderer stopped")
        }

        func flush() {
            jitterBuffer.flush()
            // Ring buffer is flushed implicitly: on next render callback,
            // the jitter buffer will be empty so ring buffer drains naturally.
            // For an immediate flush we'd need to reach into the callback's
            // captured state, but since flush is called alongside sharedBaseTs.reset(),
            // the next dequeued packets will have fresh timestamps.
        }
    }

#endif
