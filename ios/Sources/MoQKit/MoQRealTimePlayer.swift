#if os(iOS)
    import AVFoundation
    import CoreMedia
    import QuartzCore

    // MARK: - MoQRealTimePlayer

    /// Adaptive jitter-buffered player using pull-based audio via `AVAudioEngine`/`AVAudioSourceNode`.
    ///
    /// Supports three operating modes:
    /// - **Audio+Video**: Audio jitter buffer drives CMTimebase; video enqueued directly to display layer.
    /// - **Audio only**: Same audio pipeline, no video.
    /// - **Video only**: Host clock drives CMTimebase; video jitter buffer + CADisplayLink paces delivery.
    @MainActor
    public final class MoQRealTimePlayer {
        public let videoLayer: AVSampleBufferDisplayLayer
        public let events: AsyncStream<MoQPlayerEvent>

        private let tracks: [any MoQTrackInfo]
        private let targetBufferingMs: UInt64
        private let eventsContinuation: AsyncStream<MoQPlayerEvent>.Continuation

        private var audioRenderer: AudioRenderer?
        private var videoJitterBuffer: JitterBuffer<CMSampleBuffer>?
        private var timebase: CMTimebase?
        private var displayLink: CADisplayLink?

        private var videoSubscription: MoQMediaTrack?
        private var audioSubscription: MoQMediaTrack?
        private var videoFrameProcessor: VideoFrameProcessor?
        private var layerStatusObserver: NSKeyValueObservation?

        private var videoTask: Task<Void, Never>?
        private var audioTask: Task<Void, Never>?
        private var coordinatorTask: Task<Void, Never>?

        private let audioLatencyTracker = LatencyTracker()
        private let videoLatencyTracker = LatencyTracker()

        private let mode: Mode

        private enum Mode {
            case audioVideo
            case audioOnly
            case videoOnly
        }

        private nonisolated var hasVideoTrack: Bool {
            tracks.contains(where: { $0 is MoQVideoTrackInfo })
        }
        private nonisolated var hasAudioTrack: Bool {
            tracks.contains(where: { $0 is MoQAudioTrackInfo })
        }

        public init(
            tracks: [any MoQTrackInfo],
            targetBufferingMs: UInt64 = 100
        ) throws {
            if tracks.isEmpty || tracks.count > 2 {
                throw MoQSessionError.invalidConfiguration("expected one or two tracks")
            }

            self.tracks = tracks
            self.targetBufferingMs = targetBufferingMs
            self.videoLayer = AVSampleBufferDisplayLayer()

            let hasVideo = tracks.contains(where: { $0 is MoQVideoTrackInfo })
            let hasAudio = tracks.contains(where: { $0 is MoQAudioTrackInfo })
            if hasVideo && hasAudio {
                mode = .audioVideo
            } else if hasAudio {
                mode = .audioOnly
            } else {
                mode = .videoOnly
            }

            var cont: AsyncStream<MoQPlayerEvent>.Continuation!
            self.events = AsyncStream { cont = $0 }
            self.eventsContinuation = cont
        }

        // MARK: - Public API

        public nonisolated var latency: LatencyInfo {
            LatencyInfo(
                audioMs: hasAudioTrack ? audioLatencyTracker.latencyMs : nil,
                videoMs: hasVideoTrack ? videoLatencyTracker.latencyMs : nil
            )
        }

        public func play() async throws {
            guard videoTask == nil && audioTask == nil else { return }

            try await subscribe()

            let targetUs = targetBufferingMs * 1000
            
            MoQLogger.player.debug("Target buffering set to: \(targetUs)us")


            // Shared base timestamp so audio timebase and video PTS use the same zero point
            let sharedBaseTs = BaseTimestamp()

            switch mode {
            case .audioVideo, .audioOnly:
                if let aInfo = tracks.compactMap({ $0 as? MoQAudioTrackInfo }).first {
                    let renderer = try AudioRenderer(
                        config: aInfo.config,
                        targetBufferingUs: targetUs,
                        sharedBaseTs: sharedBaseTs,
                        latencyTracker: audioLatencyTracker
                    )
                    try renderer.start()
                    self.audioRenderer = renderer
                    self.timebase = renderer.timebase

                    if mode == .audioVideo {
                        videoLayer.controlTimebase = renderer.timebase
                    }
                }
            case .videoOnly:
                setupVideoOnlyPipeline(targetBufferingUs: targetUs)
            }

            let layer = videoLayer
            let continuation = eventsContinuation
            let audioLatency = audioLatencyTracker
            let videoLatency = videoLatencyTracker

            // Audio ingest task
            if let aTrack = audioSubscription, let renderer = audioRenderer {
                let audioTracer = PacketTimingTracer(kind: .audio) { report in
                    MoQLogger.player.debug("\(report)")
                }
                let jitter = renderer.jitterBuffer

                audioTask = Task.detached {
                    var lastPtsUs: UInt64 = 0
                    var firstFrame = true
                    for await frame in aTrack.frames {
                        if Task.isCancelled { break }
                        do {
                            audioLatency.calibrate(ptsUs: frame.timestampUs)

                            // Discontinuity detection
                            if frame.keyframe && lastPtsUs > 0 {
                                let diff =
                                    frame.timestampUs > lastPtsUs
                                    ? frame.timestampUs - lastPtsUs
                                    : lastPtsUs - frame.timestampUs
                                if diff > 500_000 {
                                    MoQLogger.player.debug(
                                        "Audio discontinuity detected, flushing")
                                    renderer.flush()
                                    sharedBaseTs.reset()
                                    audioLatency.reset()
                                }
                            }
                            lastPtsUs = frame.timestampUs

                            let pcm = try renderer.decoder.decode(payload: frame.payload)
                            jitter.insert(item: pcm, timestampUs: frame.timestampUs)
                            audioTracer.record(ptsUs: frame.timestampUs)

                            if firstFrame {
                                firstFrame = false
                                continuation.yield(.trackPlaying(.audio))
                            }
                        } catch {
                            MoQLogger.player.error("Audio decode error: \(error)")
                            continuation.yield(.error(.audio, error.localizedDescription))
                        }
                    }
                    if !Task.isCancelled {
                        continuation.yield(.trackStopped(.audio))
                    }
                }
            }

            // Video ingest task
            if let vTrack = videoSubscription, let processor = videoFrameProcessor,
                processor.canProcess
            {
                let videoTracer = PacketTimingTracer(kind: .video) { report in
                    MoQLogger.player.debug("\(report)")
                }
                let videoJitter = videoJitterBuffer  // nil for audioVideo mode

                videoTask = Task.detached {
                    var lastPtsUs: UInt64 = 0
                    var firstFrame = true
                    for await frame in vTrack.frames {
                        if Task.isCancelled { break }
                        do {
                            videoLatency.calibrate(ptsUs: frame.timestampUs)

                            // Discontinuity detection
                            if frame.keyframe && lastPtsUs > 0 {
                                let diff =
                                    frame.timestampUs > lastPtsUs
                                    ? frame.timestampUs - lastPtsUs
                                    : lastPtsUs - frame.timestampUs
                                if diff > 500_000 {
                                    MoQLogger.player.debug(
                                        "Video discontinuity detected, flushing")
                                    if let vj = videoJitter {
                                        vj.flush()
                                    } else {
                                        layer.flush()
                                    }
                                    sharedBaseTs.reset()
                                    videoLatency.reset()
                                }
                            }
                            lastPtsUs = frame.timestampUs

                            let baseUs = sharedBaseTs.resolve(frame.timestampUs)
                            guard
                                let sb = try processor.process(
                                    payload: frame.payload, timestampUs: frame.timestampUs,
                                    keyframe: frame.keyframe, baseTimestampUs: baseUs
                                )
                            else { continue }
                            videoTracer.record(ptsUs: frame.timestampUs)

                            if let vj = videoJitter {
                                // Video-only mode: insert into jitter buffer for CADisplayLink to consume
                                vj.insert(item: sb, timestampUs: frame.timestampUs)
                            } else {
                                print("pushing frame mate")
                                videoLatency.record(ptsUs: frame.timestampUs)
                                layer.enqueue(sb)
                            }

                            if firstFrame {
                                firstFrame = false
                                continuation.yield(.trackPlaying(.video))
                            }
                        } catch {
                            MoQLogger.player.error("Video frame processing error: \(error)")
                            continuation.yield(.error(.video, error.localizedDescription))
                        }
                    }
                    if !Task.isCancelled {
                        continuation.yield(.trackStopped(.video))
                    }
                }
            }

            // Coordinator: wait for both tasks and emit allTracksStopped
            let vTask = videoTask
            let aTask = audioTask
            coordinatorTask = Task.detached {
                await vTask?.value
                await aTask?.value
                if !Task.isCancelled {
                    continuation.yield(.allTracksStopped)
                    continuation.finish()
                }
            }
        }

        public func pause() async {
            videoTask?.cancel()
            audioTask?.cancel()
            coordinatorTask?.cancel()
            videoTask = nil
            audioTask = nil
            coordinatorTask = nil

            audioRenderer?.stop()

            if let tb = timebase {
                CMTimebaseSetRate(tb, rate: 0)
            }

            videoJitterBuffer?.flush()

            audioLatencyTracker.reset()
            videoLatencyTracker.reset()

            videoLayer.flushAndRemoveImage()
            displayLink?.invalidate()
            displayLink = nil

            videoSubscription?.close()
            audioSubscription?.close()
            videoSubscription = nil
            audioSubscription = nil

            if hasVideoTrack {
                eventsContinuation.yield(.trackPaused(.video))
            }
            if hasAudioTrack {
                eventsContinuation.yield(.trackPaused(.audio))
            }
        }

        public func stopAll() async {
            MoQLogger.player.debug("Stopping real-time player")

            videoTask?.cancel()
            audioTask?.cancel()
            coordinatorTask?.cancel()
            videoTask = nil
            audioTask = nil
            coordinatorTask = nil

            audioRenderer?.stop()
            audioRenderer = nil

            if let tb = timebase {
                CMTimebaseSetRate(tb, rate: 0)
            }
            timebase = nil

            videoJitterBuffer?.flush()
            videoJitterBuffer = nil

            audioLatencyTracker.reset()
            videoLatencyTracker.reset()

            videoLayer.flushAndRemoveImage()
            displayLink?.invalidate()
            displayLink = nil

            videoSubscription?.close()
            audioSubscription?.close()
            videoSubscription = nil
            audioSubscription = nil

            layerStatusObserver?.invalidate()
            layerStatusObserver = nil

            try? AVAudioSession.sharedInstance().setActive(false)

            eventsContinuation.finish()
        }

        deinit {
            videoTask?.cancel()
            audioTask?.cancel()
            coordinatorTask?.cancel()
            displayLink?.invalidate()
            eventsContinuation.finish()
        }

        // MARK: - Private

        private func subscribe() async throws {
            for track in tracks {
                if let vInfo = track as? MoQVideoTrackInfo {
                    MoQLogger.player.debug(
                        "Video track: \(vInfo.name), codec=\(vInfo.config.codec), config=\(vInfo.config.debugDescription)"
                    )

                    do {
                        videoFrameProcessor = try VideoFrameProcessor(config: vInfo.config)
                    } catch {
                        MoQLogger.player.error(
                            "Failed to create video frame processor for \(vInfo.name): \(error)")
                    }
                    do {
                        videoSubscription = try await MoQMediaTrack(
                            broadcast: vInfo.broadcast, name: vInfo.name,
                            maxLatencyMs: targetBufferingMs)
                    } catch {
                        MoQLogger.player.error(
                            "Failed to subscribe to video track \(vInfo.name): \(error)")
                    }
                } else if let aInfo = track as? MoQAudioTrackInfo {
                    MoQLogger.player.debug(
                        "Audio track: \(aInfo.name), config = \(aInfo.config.debugDescription)")
                    do {
                        audioSubscription = try await MoQMediaTrack(
                            broadcast: aInfo.broadcast, name: aInfo.name,
                            maxLatencyMs: targetBufferingMs)
                    } catch {
                        MoQLogger.player.error(
                            "Failed to subscribe to audio track \(aInfo.name): \(error)")
                    }
                }
            }
        }

        // MARK: - Video-Only Pipeline (Mode C)

        private func setupVideoOnlyPipeline(targetBufferingUs: UInt64) {
            let jitter = JitterBuffer<CMSampleBuffer>(targetBufferingUs: targetBufferingUs)
            self.videoJitterBuffer = jitter

            // CMTimebase with host clock, rate=0 until buffer reaches target depth
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &tb
            )
            guard let timebase = tb else { return }
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
            self.timebase = timebase
            videoLayer.controlTimebase = timebase

            // CADisplayLink pulls frames from video jitter buffer
            let target = DisplayLinkTarget(
                jitterBuffer: jitter,
                layer: videoLayer,
                timebase: timebase,
                videoLatency: videoLatencyTracker
            )
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            self.displayLink = link

            MoQLogger.player.debug("Video-only pipeline started")
        }
    }

    // MARK: - DisplayLinkTarget

    /// CADisplayLink target for video-only mode (Mode C).
    /// Pulls frames from the video jitter buffer and enqueues them to the display layer.
    private class DisplayLinkTarget {
        let jitterBuffer: JitterBuffer<CMSampleBuffer>
        let layer: AVSampleBufferDisplayLayer
        let timebase: CMTimebase
        let videoLatency: LatencyTracker
        var timebaseStarted = false

        init(
            jitterBuffer: JitterBuffer<CMSampleBuffer>,
            layer: AVSampleBufferDisplayLayer,
            timebase: CMTimebase,
            videoLatency: LatencyTracker
        ) {
            self.jitterBuffer = jitterBuffer
            self.layer = layer
            self.timebase = timebase
            self.videoLatency = videoLatency
        }

        @objc func tick() {
            // Start timebase once buffer has enough depth
            if !timebaseStarted && jitterBuffer.state == .playing {
                timebaseStarted = true
                CMTimebaseSetRate(timebase, rate: 1.0)
            }

            // Drain available frames
            while let entry = jitterBuffer.dequeue() {
                videoLatency.record(ptsUs: entry.timestampUs)
                layer.enqueue(entry.item)
            }
        }
    }

    /// Tracks wall-clock intervals between packet enqueues to detect stalls, bursts, and OOO timestamps.
    private final class PacketTimingTracer: @unchecked Sendable {
        enum TrackKind: String { case video, audio }

        private let kind: TrackKind
        private let stallFactor: Double
        private let burstFactor: Double
        private let reportInterval: Int
        private let reportCallback: (String) -> Void
        private let lock = NSLock()

        private var lastWallNs: UInt64?
        private var lastPtsUs: UInt64?
        private var highestPtsUs: UInt64?

        private var packetCount: Int = 0
        private var wallIntervalSumMs: Double = 0
        private var ptsIntervalSumMs: Double = 0
        private var intervalCount: Int = 0
        private var stallCount: Int = 0
        private var burstCount: Int = 0
        private var outOfOrderCount: Int = 0
        private var maxGapMs: Double = 0
        private var minGapMs: Double = .greatestFiniteMagnitude
        private var maxOooDeltaMs: Double = 0

        init(
            kind: TrackKind,
            stallFactor: Double = 2.0,
            burstFactor: Double = 0.3,
            reportInterval: Int = 120,
            reportCallback: @escaping (String) -> Void
        ) {
            self.kind = kind
            self.stallFactor = stallFactor
            self.burstFactor = burstFactor
            self.reportInterval = reportInterval
            self.reportCallback = reportCallback
        }

        func record(ptsUs: UInt64) {
            let nowNs = DispatchTime.now().uptimeNanoseconds

            lock.lock()

            if let highest = highestPtsUs, ptsUs < highest {
                outOfOrderCount += 1
                let deltaMs = Double(highest - ptsUs) / 1000.0
                maxOooDeltaMs = max(maxOooDeltaMs, deltaMs)
            }
            highestPtsUs = max(highestPtsUs ?? 0, ptsUs)

            if let prevWallNs = lastWallNs, let prevPtsUs = lastPtsUs {
                let wallDeltaMs = Double(nowNs - prevWallNs) / 1_000_000.0
                let isOoo = ptsUs < prevPtsUs
                let ptsDeltaMs = isOoo ? 0.0 : Double(ptsUs - prevPtsUs) / 1000.0
                let isDiscontinuity = ptsDeltaMs > 2000.0

                if !isOoo && !isDiscontinuity {
                    wallIntervalSumMs += wallDeltaMs
                    ptsIntervalSumMs += ptsDeltaMs
                    intervalCount += 1
                    maxGapMs = max(maxGapMs, wallDeltaMs)
                    minGapMs = min(minGapMs, wallDeltaMs)

                    if ptsDeltaMs > 0 {
                        if wallDeltaMs > ptsDeltaMs * stallFactor {
                            stallCount += 1
                        } else if wallDeltaMs < ptsDeltaMs * burstFactor {
                            burstCount += 1
                        }
                    }
                }
            }

            lastWallNs = nowNs
            lastPtsUs = ptsUs
            packetCount += 1

            let shouldReport = packetCount >= reportInterval
            let snapshot: (Int, Double, Double, Int, Int, Int, Double, Double, Double)?
            if shouldReport {
                let minG = minGapMs == .greatestFiniteMagnitude ? 0.0 : minGapMs
                snapshot = (
                    packetCount,
                    intervalCount > 0 ? wallIntervalSumMs / Double(intervalCount) : 0,
                    intervalCount > 0 ? ptsIntervalSumMs / Double(intervalCount) : 0,
                    stallCount, burstCount, outOfOrderCount,
                    maxOooDeltaMs, minG, maxGapMs
                )
                packetCount = 0
                wallIntervalSumMs = 0
                ptsIntervalSumMs = 0
                intervalCount = 0
                stallCount = 0
                burstCount = 0
                outOfOrderCount = 0
                maxOooDeltaMs = 0
                maxGapMs = 0
                minGapMs = .greatestFiniteMagnitude
            } else {
                snapshot = nil
            }

            lock.unlock()

            if let (pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG) = snapshot {
                let msg = String(
                    format:
                        "[%@] %d pkts | avg wall %.1fms avg pts %.1fms | stalls: %d bursts: %d | ooo: %d (max -%.1fms) | gap [%.1f, %.1f]ms",
                    kind.rawValue, pkts, avgWall, avgPts, stalls, bursts, ooo, maxOoo, minG, maxG
                )
                self.reportCallback(msg)
            }
        }
    }

#endif
