import Foundation

/// Circular buffer for Float32 PCM samples (non-interleaved, per-channel).
/// Matches the semantics of the TypeScript AudioRingBuffer:
/// timestamp-based write positioning, stall management, gap filling, and overflow handling.
struct AudioRingBuffer {
    private var buffer: [[Float32]]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    let rate: Int
    let channels: Int
    private(set) var stalled: Bool = true

    init(rate: Int, channels: Int, latencyMs: Double) {
        precondition(channels > 0, "invalid channels")
        precondition(rate > 0, "invalid sample rate")
        precondition(latencyMs > 0, "invalid latency")

        let samples = Int(ceil(Double(rate) * latencyMs / 1000.0))
        precondition(samples > 0, "empty buffer")

        self.rate = rate
        self.channels = channels
        self.buffer = (0..<channels).map { _ in [Float32](repeating: 0, count: samples) }
    }

    /// Timestamp of the current read position in microseconds.
    var timestampUs: UInt64 {
        UInt64(Double(readIndex) / Double(rate) * 1_000_000)
    }

    /// Number of samples available to read.
    var length: Int {
        writeIndex - readIndex
    }

    /// Total capacity in samples.
    var capacity: Int {
        buffer[0].count
    }

    /// Current fill level in milliseconds.
    var fillMs: Double {
        Double(length) / Double(rate) * 1000.0
    }

    // MARK: - Bulk copy helpers

    /// Copy `count` samples from `src` into ring buffer `channel` starting at logical `pos`.
    /// Splits at the wrap point — at most 2 memcpy operations.
    private mutating func ringCopy(channel: Int, pos: Int, src: UnsafePointer<Float32>, count: Int) {
        let cap = buffer[channel].count
        let start = pos % cap
        let firstChunk = min(count, cap - start)

        buffer[channel].withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.advanced(by: start)
                .update(from: src, count: firstChunk)
            if firstChunk < count {
                dst.baseAddress!
                    .update(from: src.advanced(by: firstChunk), count: count - firstChunk)
            }
        }
    }

    /// Copy `count` samples from ring buffer `channel` starting at logical `pos` into `dst`.
    private func ringRead(channel: Int, pos: Int, dst: UnsafeMutablePointer<Float32>, count: Int) {
        let cap = buffer[channel].count
        let start = pos % cap
        let firstChunk = min(count, cap - start)

        buffer[channel].withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!.advanced(by: start), count: firstChunk)
            if firstChunk < count {
                dst.advanced(by: firstChunk)
                    .update(from: src.baseAddress!, count: count - firstChunk)
            }
        }
    }

    /// Zero-fill `count` samples in ring buffer `channel` starting at logical `pos`.
    private mutating func ringZero(channel: Int, pos: Int, count: Int) {
        let cap = buffer[channel].count
        let start = pos % cap
        let firstChunk = min(count, cap - start)

        buffer[channel].withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.advanced(by: start)
                .initialize(repeating: 0, count: firstChunk)
            if firstChunk < count {
                dst.baseAddress!
                    .initialize(repeating: 0, count: count - firstChunk)
            }
        }
    }

    // MARK: - Write / Read / Resize / Reset

    /// Resize the buffer to match a new latency target. Preserves the most recent samples.
    /// Triggers a stall to refill.
    mutating func resize(latencyMs: Double) {
        let newCapacity = Int(ceil(Double(rate) * latencyMs / 1000.0))
        guard newCapacity != capacity else { return }
        precondition(newCapacity > 0, "empty buffer")

        var newBuffer = (0..<channels).map { _ in [Float32](repeating: 0, count: newCapacity) }

        let samplesToKeep = min(length, newCapacity)
        if samplesToKeep > 0 {
            let copyStart = writeIndex - samplesToKeep
            for channel in 0..<channels {
                newBuffer[channel].withUnsafeMutableBufferPointer { dst in
                    ringRead(channel: channel, pos: copyStart, dst: dst.baseAddress!, count: samplesToKeep)
                }
            }
        }

        buffer = newBuffer
        readIndex = writeIndex - samplesToKeep
        stalled = true
    }

    /// Write samples at the position determined by the timestamp.
    /// Accepts raw channel pointers directly from `AVAudioPCMBuffer.floatChannelData`.
    /// Returns the number of samples discarded (too-old + overflow).
    @discardableResult
    mutating func write(
        timestampUs: UInt64,
        channelData: UnsafePointer<UnsafeMutablePointer<Float32>>,
        frameCount: Int
    ) -> Int {
        var start = Int(round(Double(timestampUs) / 1_000_000.0 * Double(rate)))
        var samples = frameCount
        var discarded = 0

        // First write after init/reset: anchor indices to the incoming timestamp
        // so we don't treat the gap from 0 as overflow.
        if stalled && writeIndex == 0 && readIndex == 0 {
            readIndex = start
            writeIndex = start
        }

        // Ignore samples that are too old (before the read index)
        let offset = readIndex - start
        if offset > samples {
            return samples
        } else if offset > 0 {
            discarded += offset
            samples -= offset
            start += offset
        }

        let end = start + samples

        // Check if we need to discard old samples to prevent overflow
        let overflow = end - readIndex - buffer[0].count
        if overflow >= 0 {
            stalled = false
            discarded += overflow
            readIndex += overflow
        }

        // Fill gaps with zeros if there's a discontinuity
        if start > writeIndex {
            let gapSize = min(start - writeIndex, buffer[0].count)
            for channel in 0..<channels {
                ringZero(channel: channel, pos: writeIndex, count: gapSize)
            }
        }

        // Write the actual samples
        let srcOffset = frameCount - samples
        for channel in 0..<channels {
            let src = UnsafePointer(channelData[channel])
            ringCopy(channel: channel, pos: start, src: src.advanced(by: srcOffset), count: samples)
        }

        if end > writeIndex {
            writeIndex = end
        }

        return discarded
    }

    /// Reset all state, clearing the buffer and re-entering stalled mode.
    mutating func reset() {
        writeIndex = 0
        readIndex = 0
        stalled = true
        for channel in 0..<channels {
            buffer[channel].withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.initialize(repeating: 0, count: buf.count)
            }
        }
    }

    /// Read samples into the provided output arrays. Returns how many samples were read.
    /// Returns 0 while stalled.
    mutating func read(into output: inout [[Float32]]) -> Int {
        precondition(output.count == channels, "wrong number of channels")
        guard !stalled else { return 0 }

        let samples = min(writeIndex - readIndex, output[0].count)
        guard samples > 0 else { return 0 }

        for channel in 0..<channels {
            precondition(
                output[channel].count == output[0].count, "mismatching number of samples")
            output[channel].withUnsafeMutableBufferPointer { dst in
                ringRead(channel: channel, pos: readIndex, dst: dst.baseAddress!, count: samples)
            }
        }

        readIndex += samples
        return samples
    }
}
