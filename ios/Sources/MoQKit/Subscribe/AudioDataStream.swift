import AVFoundation
import Foundation
import MoqFFI

// MARK: - Audio Sample Format

/// PCM sample representation emitted by ``AudioDataStream``.
public enum AudioSampleFormat: Sendable, Equatable {
    /// 32-bit floating point PCM.
    case float32
    /// Signed 16-bit integer PCM.
    case int16
}

// MARK: - Audio Data Format

/// Requested PCM format for ``AudioDataStream`` output.
///
/// Leave `sampleRate` or `channelCount` as `nil` to keep the subscribed track's source
/// configuration.
public struct AudioDataFormat: Sendable, Equatable {
    /// Sample representation for emitted ``AudioData/bytes``.
    public let sampleFormat: AudioSampleFormat
    /// Output sample rate in Hz. `nil` keeps the subscribed track's sample rate.
    public let sampleRate: Double?
    /// Output channel count. `nil` keeps the subscribed track's channel count.
    public let channelCount: UInt32?

    public init(
        sampleFormat: AudioSampleFormat = .float32,
        sampleRate: Double? = nil,
        channelCount: UInt32? = nil
    ) {
        self.sampleFormat = sampleFormat
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

// MARK: - Audio Data

/// One decoded PCM audio chunk emitted by ``AudioDataStream``.
public struct AudioData: Sendable, Equatable {
    /// Interleaved PCM bytes in ``sampleFormat``.
    public let bytes: Data
    /// Presentation timestamp in microseconds, relative to the stream origin.
    public let timestampUs: UInt64
    /// PCM sample rate in Hz.
    public let sampleRate: Double
    /// Number of audio channels.
    public let channelCount: UInt32
    /// Sample representation for ``bytes``.
    public let sampleFormat: AudioSampleFormat
    /// Number of PCM frames in ``bytes``.
    public let frameCount: UInt32
}

// MARK: - Audio Data Stream

/// Subscribes to one catalog audio track and emits decoded PCM chunks.
///
/// `AudioDataStream` is independent from ``Player`` and is intended for apps that want to
/// process audio instead of rendering it.
public final class AudioDataStream: @unchecked Sendable {
    /// Decoded PCM chunks.
    ///
    /// This is a live stream with a small bounded buffer. If the consumer falls behind, older
    /// decoded chunks may be dropped in favor of newer chunks. The stream finishes when the
    /// audio track ends, when ``close()`` is called, or with an error if subscription, reading,
    /// decoding, or format conversion fails.
    public let audio: AsyncThrowingStream<AudioData, Error>

    private static let bufferedAudioDataLimit = 3
    private let lock = UnfairLock()
    private let consumer: MoqMediaConsumer
    private let continuation: AsyncThrowingStream<AudioData, Error>.Continuation
    private var readTask: Task<Void, Never>?
    private var closed = false

    /// Creates a decoded audio stream for an advertised catalog audio track.
    ///
    /// - Parameters:
    ///   - catalog: Catalog that advertised `track`.
    ///   - track: Audio track to subscribe to and decode.
    ///   - format: Requested PCM output format. Defaults to source-rate Float32 PCM.
    ///   - targetBuffering: Target live buffering depth. Higher values improve resilience to
    ///     network jitter at the cost of increased end-to-end latency.
    public init(
        catalog: Catalog,
        track: AudioTrackInfo,
        format: AudioDataFormat = AudioDataFormat(),
        targetBuffering: Duration = .milliseconds(100)
    ) throws {
        let decoder = try AudioDecoder(config: track.rawConfig)
        let converter = try AudioDataConverter(
            sourceFormat: decoder.outputFormat,
            requestedFormat: format
        )
        let consumer = try catalog.broadcast.subscribeMedia(
            name: track.name,
            container: track.rawConfig.container,
            maxLatencyMs: targetBuffering.millisecondsUInt64Clamped
        )

        let audioStream = Self.makeBufferedAudioStream()
        let audioContinuation = audioStream.continuation
        self.audio = audioStream.stream
        self.consumer = consumer
        self.continuation = audioContinuation

        self.readTask = Task.detached {
            defer {
                consumer.cancel()
                audioContinuation.finish()
            }

            while !Task.isCancelled {
                do {
                    guard let frame = try await consumer.next() else { return }
                    guard !Task.isCancelled else { return }

                    let pcm = try decoder.decode(payload: frame.payload)
                    let audioData = try converter.convert(
                        pcm,
                        timestampUs: frame.timestampUs
                    )
                    audioContinuation.yield(audioData)
                } catch MoqError.Cancelled {
                    return
                } catch {
                    audioContinuation.finish(throwing: error)
                    return
                }
            }
        }

        audioContinuation.onTermination = { [weak self] _ in
            self?.close()
        }
    }

    /// Creates a decoded audio stream by resolving `trackName` from `catalog.audioTracks`.
    ///
    /// - Throws: ``SessionError/invalidConfiguration(_:)`` if no advertised audio track has
    ///   the requested name.
    public convenience init(
        catalog: Catalog,
        trackName: String,
        format: AudioDataFormat = AudioDataFormat(),
        targetBuffering: Duration = .milliseconds(100)
    ) throws {
        guard let track = catalog.audioTracks.first(where: { $0.name == trackName }) else {
            throw SessionError.invalidConfiguration(
                "Unknown audio track '\(trackName)' for catalog '\(catalog.path)'"
            )
        }
        try self.init(
            catalog: catalog,
            track: track,
            format: format,
            targetBuffering: targetBuffering
        )
    }

    /// Cancels the subscription and finishes ``audio``.
    ///
    /// Safe to call multiple times.
    public func close() {
        var taskToCancel: Task<Void, Never>?
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            taskToCancel = readTask
            readTask = nil
            return true
        }

        guard shouldClose else { return }
        consumer.cancel()
        taskToCancel?.cancel()
        continuation.finish()
    }

    deinit {
        close()
    }

    static func makeBufferedAudioStream() -> (
        stream: AsyncThrowingStream<AudioData, Error>,
        continuation: AsyncThrowingStream<AudioData, Error>.Continuation
    ) {
        var pendingContinuation: AsyncThrowingStream<AudioData, Error>.Continuation?
        let stream = AsyncThrowingStream<AudioData, Error>(
            bufferingPolicy: .bufferingNewest(Self.bufferedAudioDataLimit)
        ) { continuation in
            pendingContinuation = continuation
        }
        guard let continuation = pendingContinuation else {
            preconditionFailure("AsyncThrowingStream did not provide a continuation")
        }
        return (stream, continuation)
    }
}

// MARK: - Audio Data Converter

final class AudioDataConverter: @unchecked Sendable {
    private let sampleFormat: AudioSampleFormat
    private let processingFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(sourceFormat: AVAudioFormat, requestedFormat: AudioDataFormat) throws {
        if let sampleRate = requestedFormat.sampleRate, sampleRate <= 0 {
            throw SessionError.invalidConfiguration("Audio data sample rate must be greater than zero")
        }
        if let channelCount = requestedFormat.channelCount, channelCount == 0 {
            throw SessionError.invalidConfiguration("Audio data channel count must be greater than zero")
        }

        let sampleRate = requestedFormat.sampleRate ?? sourceFormat.sampleRate
        let channelCount = requestedFormat.channelCount ?? UInt32(sourceFormat.channelCount)

        guard
            let processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            )
        else {
            throw SessionError.audioDecoderFailed("Failed to create audio data output format")
        }

        self.sampleFormat = requestedFormat.sampleFormat
        self.processingFormat = processingFormat

        if sourceFormat == processingFormat {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: processingFormat) else {
                throw SessionError.audioDecoderFailed("Failed to create audio data format converter")
            }
            self.converter = converter
        }
    }

    func convert(_ sourceBuffer: AVAudioPCMBuffer, timestampUs: UInt64) throws -> AudioData {
        let outputBuffer = try convertFormatIfNeeded(sourceBuffer)
        let bytes: Data

        switch sampleFormat {
        case .float32:
            bytes = try Self.float32InterleavedBytes(from: outputBuffer)
        case .int16:
            bytes = try Self.int16InterleavedBytes(from: outputBuffer)
        }

        return AudioData(
            bytes: bytes,
            timestampUs: timestampUs,
            sampleRate: outputBuffer.format.sampleRate,
            channelCount: UInt32(outputBuffer.format.channelCount),
            sampleFormat: sampleFormat,
            frameCount: UInt32(outputBuffer.frameLength)
        )
    }

    private func convertFormatIfNeeded(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return sourceBuffer }

        let targetFrameCount = AVAudioFrameCount(
            ceil(
                Double(sourceBuffer.frameLength) * processingFormat.sampleRate
                    / sourceBuffer.format.sampleRate
            ) * 2
        )
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: max(1, targetFrameCount)
            )
        else {
            throw SessionError.audioDecoderFailed("Failed to allocate audio data output buffer")
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            let message = error?.localizedDescription ?? "unknown"
            throw SessionError.audioDecoderFailed("Audio data conversion failed: \(message)")
        }
        if let error {
            throw SessionError.audioDecoderFailed(
                "Audio data conversion failed: \(error.localizedDescription)"
            )
        }

        return outputBuffer
    }

    private static func float32InterleavedBytes(from buffer: AVAudioPCMBuffer) throws -> Data {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0 else { return Data() }
        guard let channels = buffer.floatChannelData else {
            throw SessionError.audioDecoderFailed("Audio data conversion expected Float32 PCM")
        }

        var data = Data()
        data.reserveCapacity(frameCount * channelCount * MemoryLayout<Float32>.size)

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                data.appendLittleEndian(channels[channel][frame].bitPattern)
            }
        }

        return data
    }

    private static func int16InterleavedBytes(from buffer: AVAudioPCMBuffer) throws -> Data {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0 else { return Data() }
        guard let channels = buffer.floatChannelData else {
            throw SessionError.audioDecoderFailed("Audio data conversion expected Float32 PCM")
        }

        var data = Data()
        data.reserveCapacity(frameCount * channelCount * MemoryLayout<Int16>.size)

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let sample = max(-1, min(1, channels[channel][frame]))
                let scale: Float32 = sample < 0 ? 32_768 : 32_767
                let value = Int16(clamping: Int((sample * scale).rounded()))
                data.appendLittleEndian(value)
            }
        }

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
