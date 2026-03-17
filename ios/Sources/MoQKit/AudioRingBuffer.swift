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
                let src = buffer[channel]
                for i in 0..<samplesToKeep {
                    let srcPos = (copyStart + i) % src.count
                    let dstPos = i % newCapacity
                    newBuffer[channel][dstPos] = src[srcPos]
                }
            }
        }

        buffer = newBuffer
        readIndex = writeIndex - samplesToKeep
        stalled = true
    }

    /// Write samples at the position determined by the timestamp.
    /// Handles gaps (zero-fill), old samples (skip), and overflow (discard oldest, exit stall).
    mutating func write(timestampUs: UInt64, data: [[Float32]]) {
        precondition(data.count == channels, "wrong number of channels")

        var start = Int(round(Double(timestampUs) / 1_000_000.0 * Double(rate)))
        var samples = data[0].count

        // Ignore samples that are too old (before the read index)
        let offset = readIndex - start
        if offset > samples {
            // All samples are too old, ignore them
            return
        } else if offset > 0 {
            // Some samples are too old, skip them
            samples -= offset
            start += offset
        }

        let end = start + samples

        // Check if we need to discard old samples to prevent overflow
        let overflow = end - readIndex - buffer[0].count
        if overflow >= 0 {
            // Discard old samples and exit stalled mode
            stalled = false
            readIndex += overflow
        }

        // Fill gaps with zeros if there's a discontinuity
        if start > writeIndex {
            let gapSize = min(start - writeIndex, buffer[0].count)
            for channel in 0..<channels {
                for i in 0..<gapSize {
                    let writePos = (writeIndex + i) % buffer[channel].count
                    buffer[channel][writePos] = 0
                }
            }
        }

        // Write the actual samples
        for channel in 0..<channels {
            let src = data[channel]
            let srcStart = src.count - samples

            for i in 0..<samples {
                let writePos = (start + i) % buffer[channel].count
                buffer[channel][writePos] = src[srcStart + i]
            }
        }

        // Update write index, but only if we're moving forward
        if end > writeIndex {
            writeIndex = end
        }
    }

    /// Reset all state, clearing the buffer and re-entering stalled mode.
    mutating func reset() {
        writeIndex = 0
        readIndex = 0
        stalled = true
        for channel in 0..<channels {
            buffer[channel] = [Float32](repeating: 0, count: buffer[channel].count)
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
            let src = buffer[channel]
            for i in 0..<samples {
                let readPos = (readIndex + i) % src.count
                output[channel][i] = src[readPos]
            }
        }

        if samples < output[0].count {
            print("will stall motherfucketr")

        }
        readIndex += samples
        return samples
    }
}
