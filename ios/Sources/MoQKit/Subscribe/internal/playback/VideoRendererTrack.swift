import AVFoundation
import CoreMedia
import MoQKitFFI

// MARK: - CompressedVideoFrame

/// A compressed video frame ready for enqueuing to AVSampleBufferDisplayLayer.
struct VideoRendererSample {
    let sampleBuffer: CMSampleBuffer
    let isKeyframe: Bool
}

// MARK: - VideoRendererTrack

/// Owns the `JitterBuffer` and `VideoFrameProcessor` for one video rendition.
///
/// Thread-safe: all mutable state (buffer + callback) is guarded by `lock`.
/// The `insert` / `dequeue` / `peekFront` path is called from different threads
/// (ingest task vs. `enqueueQueue`) so all public methods take the lock.
///
/// `onDataAvailable` is fired **outside** the lock to avoid potential deadlocks
/// with callers that re-enter under the same lock.
final class VideoRendererTrack: @unchecked Sendable {
    let processor: VideoFrameProcessor

    private var buffer: JitterBuffer<VideoRendererSample>
    private let lock = UnfairLock()
    private var onDataAvailable: (() -> Void)?

    init(config: MoqVideo, targetBufferingMs: UInt64) throws {
        self.processor = try VideoFrameProcessor(config: config)
        self.buffer = JitterBuffer<VideoRendererSample>(
            targetBufferingUs: targetBufferingMs * 1_000)
    }

    // MARK: - Insertion (called from ingest task)

    /// Process a raw frame payload through the `VideoFrameProcessor` and insert the result
    /// into the jitter buffer.
    func insert(payload: Data, timestampUs: UInt64, keyframe: Bool) {
        var notify: (() -> Void)? = nil

        lock.withLock {
            do {
                guard
                    let sb = try processor.process(
                        payload: payload, timestampUs: timestampUs, keyframe: keyframe)
                else { return }

                let sample = VideoRendererSample(sampleBuffer: sb, isKeyframe: keyframe)

                let shouldNotify = buffer.insert(item: sample, timestampUs: timestampUs)
                let pendingKeyframe = buffer.state == .pending && keyframe

                notify = (shouldNotify || pendingKeyframe) ? onDataAvailable : nil
            } catch {
                KitLogger.player.error("Failed to insert video sample: \(error)")
            }
        }

        notify?()
    }

    // MARK: - Consumption (called from enqueueQueue)

    /// Peek at the front entry's metadata without removing it.
    func peekFront() -> (timestampUs: UInt64, isKeyframe: Bool)? {
        lock.withLock {
            guard let entry = buffer.peekFront() else { return nil }
            return (entry.timestampUs, entry.item.isKeyframe)
        }
    }

    /// Dequeue the oldest entry. Returns `(nil, false)` when buffering or empty.
    func dequeue() -> (JitterBuffer<VideoRendererSample>.Entry?, Bool) {
        lock.withLock { buffer.dequeue() }
    }

    // MARK: - State control (called from enqueueQueue)

    func setBufferState(_ state: JitterBuffer<VideoRendererSample>.State) {
        lock.withLock { buffer.setState(state) }
    }

    /// PTS of the first keyframe currently stored in the buffer, or `nil`.
    /// Scans from the front; safe to call from `enqueueQueue`.
    var firstKeyframePts: UInt64? {
        lock.withLock {
            buffer.firstPts(where: { $0.item.isKeyframe })
        }
    }

    /// Drop non-keyframe frames whose PTS is strictly less than `pts`.
    /// Stops at the first keyframe or at the first frame with PTS ≥ `pts`.
    /// Used to align the pending buffer's front to the cut-in keyframe before swap.
    func discardNonKeyframesBeforePts(_ pts: UInt64) {
        lock.withLock {
            while let front = buffer.peekFront(),
                !front.item.isKeyframe,
                front.timestampUs < pts
            {
                buffer.discardFront()
            }
        }
    }

    /// Drop the front entry unconditionally (ignores JitterBuffer state).
    /// Returns `true` if an entry was removed.
    @discardableResult
    func discardFront() -> Bool {
        lock.withLock { buffer.discardFront() }
    }

    // MARK: - Configuration

    func setOnDataAvailable(_ callback: (() -> Void)?) {
        lock.withLock { onDataAvailable = callback }
    }

    func updateTargetBuffering(ms: UInt64) {
        lock.withLock { buffer.updateTargetBuffering(us: ms * 1_000) }
    }

    func flush() {
        lock.withLock { buffer.flush() }
    }

    // MARK: - State

    var state: JitterBuffer<VideoRendererSample>.State {
        lock.withLock { buffer.state }
    }

    var depthMs: Double {
        lock.withLock { buffer.depthMs }
    }
}
