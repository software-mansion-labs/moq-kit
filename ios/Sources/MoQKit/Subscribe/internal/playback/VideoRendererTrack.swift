import AVFoundation
import CoreMedia
import MoqFFI

// MARK: - CompressedVideoFrame

/// A compressed video frame ready for enqueuing to AVSampleBufferDisplayLayer.
struct VideoRendererSample {
    let sampleBuffer: CMSampleBuffer
    let isKeyframe: Bool
}

enum VideoFrameInsertOutcome {
    case admitted(depth: BufferDepth, evictions: [AdmissionEffect])
    case rejected(AdmissionRejectReason)
    case invalidPayload

    var accepted: Bool {
        if case .admitted = self { return true }
        return false
    }
}

// MARK: - VideoRendererTrack

/// Owns the bounded `FrameBuffer`, `TrackTimeline`, and `VideoFrameProcessor` for one rendition.
///
/// Thread-safe: all mutable state (buffer + callback) is guarded by `lock`.
/// The `insert` / `dequeue` / `peekFront` path is called from different threads
/// (ingest task vs. `enqueueQueue`) so all public methods take the lock.
///
/// `onDataAvailable` is fired **outside** the lock to avoid potential deadlocks
/// with callers that re-enter under the same lock.
final class VideoRendererTrack: @unchecked Sendable {
    enum State {
        case buffering
        case pending
        case playing
    }

    struct Entry {
        let timestampUs: UInt64
        let item: VideoRendererSample
    }

    let trackName: String
    let trackEpoch: TrackEpoch
    let processor: VideoFrameProcessor
    let timeline: TrackTimeline

    private var buffer: FrameBuffer<VideoRendererSample>
    private var mode: State = .buffering
    private var targetBufferingUs: UInt64
    private let lock = UnfairLock()
    private var onDataAvailable: (() -> Void)?

    init(
        trackName: String,
        epoch: TrackEpoch,
        config: MoqVideo,
        targetBuffering: Duration
    ) throws {
        self.trackName = trackName
        self.trackEpoch = epoch
        self.processor = try VideoFrameProcessor(config: config)
        self.timeline = TrackTimeline(
            policy: TimelinePolicy(
                targetLatencyUs: Int64(clamping: targetBuffering.microsecondsUInt64Clamped)
            )
        )
        self.buffer = FrameBuffer<VideoRendererSample>()
        self.targetBufferingUs = targetBuffering.microsecondsUInt64Clamped
    }

    // MARK: - Insertion (called from ingest task)

    /// Process a raw frame payload through the `VideoFrameProcessor` and insert the result
    /// into the frame buffer.
    func insert(
        payload: Data,
        timestampUs: UInt64,
        keyframe: Bool
    ) -> VideoFrameInsertOutcome {
        var notify: (() -> Void)? = nil
        var outcome: VideoFrameInsertOutcome = .invalidPayload

        lock.withLock {
            do {
                guard
                    let sb = try processor.process(
                        payload: payload, timestampUs: timestampUs, keyframe: keyframe)
                else { return }

                let sample = VideoRendererSample(sampleBuffer: sb, isKeyframe: keyframe)
                guard timestampUs <= UInt64(Int64.max) else { return }
                let effects = buffer.offer(
                    PipelineFrame(
                        payload: sample,
                        timestampUs: Int64(timestampUs),
                        keyframe: keyframe,
                        sizeBytes: payload.count,
                        epoch: trackEpoch
                    )
                )
                if case .rejected(let reason) = effects.first {
                    outcome = .rejected(reason)
                    return
                }
                let accepted = buffer.contains {
                    $0.timestampUs == Int64(timestampUs) && $0.keyframe == keyframe
                }
                guard accepted else {
                    outcome = .rejected(.frameTooLarge)
                    return
                }
                outcome = .admitted(
                    depth: buffer.depth(),
                    evictions: effects.filter {
                        if case .evictedGop = $0 { return true }
                        return false
                    }
                )
                let wasEmpty = buffer.depth().frames == 1
                let becamePlayable = updateBufferingStateIfReady()
                let pendingKeyframe = mode == .pending && keyframe

                notify = (becamePlayable || (wasEmpty && mode == .playing) || pendingKeyframe)
                    ? onDataAvailable
                    : nil
            } catch {
                KitLogger.player.error("Failed to insert video sample: \(error)")
            }
        }

        notify?()
        return outcome
    }

    // MARK: - Consumption (called from enqueueQueue)

    /// Peek at the front entry's metadata without removing it.
    func peekFront() -> (timestampUs: UInt64, isKeyframe: Bool)? {
        lock.withLock { () -> (timestampUs: UInt64, isKeyframe: Bool)? in
            guard let entry = buffer.peekFront() else { return nil }
            return (UInt64(entry.timestampUs), entry.keyframe)
        }
    }

    /// Dequeue the oldest entry. Returns `(nil, false)` when buffering or empty.
    func dequeue() -> (Entry?, Bool) {
        lock.withLock {
            guard mode == .playing, let frame = buffer.removeFront() else {
                return (nil, false)
            }
            let target = timeline.targetPlaybackUs()
            let playable = target.map { frame.timestampUs >= $0 } ?? true
            return (
                Entry(timestampUs: UInt64(frame.timestampUs), item: frame.payload),
                playable
            )
        }
    }

    // MARK: - State control (called from enqueueQueue)

    func setBufferState(_ state: State) {
        lock.withLock { mode = state }
    }

    /// PTS of the first keyframe currently stored in the buffer, or `nil`.
    /// Scans from the front; safe to call from `enqueueQueue`.
    var firstKeyframePts: UInt64? {
        lock.withLock {
            buffer.first(where: \.keyframe).map { UInt64($0.timestampUs) }
        }
    }

    /// Drop non-keyframe frames whose PTS is strictly less than `pts`.
    /// Stops at the first keyframe or at the first frame with PTS ≥ `pts`.
    /// Used to align the pending buffer's front to the cut-in keyframe before swap.
    func discardNonKeyframesBeforePts(_ pts: UInt64) {
        lock.withLock {
            while let front = buffer.peekFront(),
                !front.keyframe,
                front.timestampUs < Int64(clamping: pts)
            {
                _ = buffer.removeFront()
            }
        }
    }

    /// Drop the front entry unconditionally (ignores playback state).
    /// Returns `true` if an entry was removed.
    @discardableResult
    func discardFront() -> Bool {
        lock.withLock { buffer.removeFront() != nil }
    }

    // MARK: - Configuration

    func setOnDataAvailable(_ callback: (() -> Void)?) {
        lock.withLock { onDataAvailable = callback }
    }

    @discardableResult
    func updateTargetBuffering(_ targetBuffering: Duration) -> Bool {
        timeline.setTargetLatencyUs(
            Int64(clamping: targetBuffering.microsecondsUInt64Clamped)
        )
        return lock.withLock {
            targetBufferingUs = targetBuffering.microsecondsUInt64Clamped
            return updateBufferingStateIfReady()
        }
    }

    func flush() {
        lock.withLock {
            _ = buffer.reset(epoch: trackEpoch)
            mode = .buffering
        }
    }

    // MARK: - State

    var state: State {
        lock.withLock { mode }
    }

    var depthMs: Double {
        lock.withLock { Double(buffer.depth().durationUs) / 1_000 }
    }

    var depth: Duration {
        lock.withLock { .microsecondsClamped(buffer.depth().durationUs) }
    }

    var diagnosticDepth: BufferDepth {
        lock.withLock {
            buffer.depth()
        }
    }

    var targetBuffering: Duration {
        lock.withLock { .microsecondsClamped(targetBufferingUs) }
    }

    func targetPlaybackPTS() -> UInt64? {
        guard let target = timeline.targetPlaybackUs(), target >= 0 else { return nil }
        return UInt64(target)
    }

    var frontFrameIntervalUs: UInt64? {
        lock.withLock { buffer.frontFrameIntervalUs.map(UInt64.init) }
    }

    private func updateBufferingStateIfReady() -> Bool {
        guard mode == .buffering else { return false }
        let depth = buffer.depth()
        guard depth.frames >= 2, depth.durationUs >= targetBufferingUs else { return false }
        mode = .playing
        return true
    }
}
