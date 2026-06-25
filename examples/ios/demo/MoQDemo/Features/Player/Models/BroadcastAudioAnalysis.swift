import Accelerate
import Combine
import Foundation
import MoQKit

@MainActor
final class BroadcastAudioAnalysis: ObservableObject {
    private static let audioWaveformFftSize = 1024
    private static let audioWaveformLatencyUs: UInt64 = 120_000

    @Published private(set) var state: AudioAnalysisState = .idle
    @Published private(set) var waveform = AudioWaveformSnapshot()

    private var audioDataStream: AudioDataStream?
    private var audioAnalysisTask: Task<Void, Never>?
    private var audioSpectrumAnalyzer: AudioSpectrumAnalyzer?
    private var audioAnalysisToken = UUID()

    var isActive: Bool {
        state.isActive
    }

    func start(
        catalog: Catalog,
        track selectedAudioTrack: AudioTrackInfo?,
        targetLatencyMs: Double
    ) {
        guard audioAnalysisTask == nil else { return }
        guard let selectedAudioTrack else {
            state = .failed("No playable audio track selected")
            return
        }

        let targetBuffering = Duration.milliseconds(
            Int64(min(max(targetLatencyMs, 0), Double(Int64.max)))
        )
        let stream: AudioDataStream
        do {
            stream = try AudioDataStream(
                catalog: catalog,
                track: selectedAudioTrack,
                format: AudioDataFormat(sampleFormat: .float32),
                targetBuffering: targetBuffering
            )
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let token = UUID()
        audioAnalysisToken = token
        audioDataStream = stream
        waveform = AudioWaveformSnapshot()
        state = .starting

        let spectrumAnalyzer = AudioSpectrumAnalyzer(
            fftSize: Self.audioWaveformFftSize,
            latencyUs: Self.audioWaveformLatencyUs
        )
        audioSpectrumAnalyzer = spectrumAnalyzer

        audioAnalysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                stream.close()
                if self.audioAnalysisToken == token {
                    self.audioDataStream = nil
                    self.audioAnalysisTask = nil
                    self.audioSpectrumAnalyzer = nil
                }
            }

            do {
                for try await audio in stream.audio {
                    guard !Task.isCancelled, self.audioAnalysisToken == token else { return }
                    spectrumAnalyzer.ingest(audio)
                    if self.state != .running {
                        self.state = .running
                    }
                }

                if self.audioAnalysisToken == token {
                    self.state = .stopped
                }
            } catch is CancellationError {
            } catch {
                if self.audioAnalysisToken == token {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop(reset: Bool = false) {
        audioAnalysisToken = UUID()
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        audioDataStream?.close()
        audioDataStream = nil
        audioSpectrumAnalyzer = nil
        state = reset ? .idle : .stopped
        if reset {
            waveform = AudioWaveformSnapshot()
        }
    }

    func refreshWaveform(displayInterval: TimeInterval) {
        guard isActive, let audioSpectrumAnalyzer else { return }

        guard let nextWaveform = audioSpectrumAnalyzer.nextSnapshot(
            displayInterval: displayInterval
        ) else {
            return
        }

        if nextWaveform != waveform {
            waveform = nextWaveform
        }
    }
}

enum AudioAnalysisState: Equatable {
    case idle
    case starting
    case running
    case stopped
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .starting:
            return "starting..."
        case .running:
            return "running"
        case .stopped:
            return "stopped"
        case .failed(let message):
            return "error: \(message)"
        }
    }
}

struct AudioWaveformSnapshot: Equatable {
    static let barCount = 64

    var samples: [Float] = []
    var sampleRate: Double?
    var channelCount: UInt32?
}

private enum AudioWaveformAnalyzer {
    static func bytesPerSample(for sampleFormat: AudioSampleFormat) -> Int {
        switch sampleFormat {
        case .float32:
            return MemoryLayout<Float32>.size
        case .int16:
            return MemoryLayout<Int16>.size
        }
    }

    static func frameAmplitude(
        _ frame: Int,
        channelCount: Int,
        bytesPerSample: Int,
        audio: AudioData
    ) -> Float {
        var total: Float = 0
        var validChannels = 0

        for channel in 0..<channelCount {
            let offset = (frame * channelCount + channel) * bytesPerSample
            let sample: Float?
            switch audio.sampleFormat {
            case .float32:
                sample = float32Sample(at: offset, in: audio.bytes)
            case .int16:
                sample = int16Sample(at: offset, in: audio.bytes)
            }

            guard let sample, sample.isFinite else { continue }
            total += min(max(sample, -1), 1)
            validChannels += 1
        }

        guard validChannels > 0 else { return 0 }
        return total / Float(validChannels)
    }

    private static func float32Sample(at offset: Int, in bytes: Data) -> Float? {
        guard offset + 3 < bytes.count else { return nil }
        let bits = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }

    private static func int16Sample(at offset: Int, in bytes: Data) -> Float? {
        guard offset + 1 < bytes.count else { return nil }
        let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let value = Int16(bitPattern: bits)
        return Float(value) / 32_768
    }
}

/// Frequency-spectrum (equalizer) analyzer.
///
/// Audio is downmixed to mono and pushed into a rolling sample buffer. On each display
/// refresh the most recent `fftSize` samples (delayed by `latencyUs` so the bars stay in
/// sync with the audible playback) are windowed and transformed with a real FFT. The
/// magnitude spectrum is folded into `AudioWaveformSnapshot.barCount` log-spaced frequency
/// bands. Bar positions are fixed from low to high frequency; only their heights animate, so
/// the visualization is static rather than scrolling. Low-mid bands dominate for speech
/// while music spreads broadband, which makes the two visually distinct.
@MainActor
private final class AudioSpectrumAnalyzer {
    /// Lowest frequency mapped to the first bar.
    private static let minFrequency = 40.0
    /// Highest frequency mapped to the last bar (capped at Nyquist).
    private static let maxFrequency = 16_000.0
    /// dB window mapped onto the 0...1 bar range.
    private static let floorDb: Float = -62
    private static let ceilingDb: Float = -6
    /// Per-60Hz-frame smoothing factors (frame-rate compensated in `smooth`).
    private static let attackPerFrame: Float = 0.6
    private static let releasePerFrame: Float = 0.12
    private static let visualFloor: Float = 0.003

    private let fftSize: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let latencyUs: UInt64
    private let barCount = AudioWaveformSnapshot.barCount

    private let fftSetup: FFTSetup?
    private let hannWindow: [Float]

    private var sampleBuffer: [Float] = []
    private var capacity: Int
    private var hasAudio = false
    private var sampleRate: Double?
    private var channelCount: UInt32?
    private var smoothedBars: [Float] = []

    init(fftSize: Int, latencyUs: UInt64) {
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        self.latencyUs = latencyUs
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        self.capacity = fftSize * 2

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func ingest(_ audio: AudioData) {
        guard audio.sampleRate > 0 else { return }

        sampleRate = audio.sampleRate
        channelCount = audio.channelCount

        let channels = max(Int(audio.channelCount), 1)
        let bytesPerSample = AudioWaveformAnalyzer.bytesPerSample(for: audio.sampleFormat)
        let bytesPerFrame = channels * bytesPerSample
        guard bytesPerFrame > 0 else { return }

        let frameCount = min(Int(audio.frameCount), audio.bytes.count / bytesPerFrame)
        guard frameCount > 0 else { return }

        sampleBuffer.reserveCapacity(sampleBuffer.count + frameCount)
        for frame in 0..<frameCount {
            sampleBuffer.append(
                AudioWaveformAnalyzer.frameAmplitude(
                    frame,
                    channelCount: channels,
                    bytesPerSample: bytesPerSample,
                    audio: audio
                )
            )
        }
        hasAudio = true

        // Keep enough history to honor the artificial latency plus one FFT window.
        let latencySamples = Int((Double(latencyUs) / 1_000_000.0) * audio.sampleRate)
        capacity = max(fftSize * 2, latencySamples + fftSize + fftSize / 2)
        if sampleBuffer.count > capacity {
            sampleBuffer.removeFirst(sampleBuffer.count - capacity)
        }
    }

    func nextSnapshot(displayInterval: TimeInterval) -> AudioWaveformSnapshot? {
        guard hasAudio, let sampleRate, sampleBuffer.count >= fftSize else { return nil }

        // Window ends `latencySamples` before the newest sample so the bars line up with
        // what is currently audible; clamp so a full FFT window is always available.
        let latencySamples = Int((Double(latencyUs) / 1_000_000.0) * sampleRate)
        let end = min(max(sampleBuffer.count - latencySamples, fftSize), sampleBuffer.count)
        let start = end - fftSize

        var windowed = [Float](repeating: 0, count: fftSize)
        sampleBuffer.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vmul(base + start, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))
        }

        guard let magnitudes = magnitudeSpectrum(of: windowed) else { return nil }
        let targetBars = bars(from: magnitudes, sampleRate: sampleRate)
        let displayBars = smooth(targetBars, interval: displayInterval)

        return AudioWaveformSnapshot(
            samples: displayBars,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    private func magnitudeSpectrum(of windowed: [Float]) -> [Float]? {
        guard let fftSetup else { return nil }

        var realParts = [Float](repeating: 0, count: halfSize)
        var imagParts = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realParts.withUnsafeMutableBufferPointer { realBuffer in
            imagParts.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )

                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfSize
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        return magnitudes
    }

    private func bars(from magnitudes: [Float], sampleRate: Double) -> [Float] {
        let nyquist = sampleRate / 2
        let maxFrequency = min(Self.maxFrequency, nyquist)
        guard maxFrequency > Self.minFrequency, halfSize > 1 else {
            return Array(repeating: 0, count: barCount)
        }

        let binHz = sampleRate / Double(fftSize)
        let logMin = log10(Self.minFrequency)
        let logMax = log10(maxFrequency)
        let normalization = 1 / Float(fftSize)
        let dbRange = Self.ceilingDb - Self.floorDb

        var result = [Float](repeating: 0, count: barCount)
        for bar in 0..<barCount {
            let lowFreq = pow(10, logMin + (logMax - logMin) * Double(bar) / Double(barCount))
            let highFreq = pow(10, logMin + (logMax - logMin) * Double(bar + 1) / Double(barCount))

            var lowBin = max(1, Int((lowFreq / binHz).rounded(.down)))
            var highBin = Int((highFreq / binHz).rounded(.up))
            lowBin = min(lowBin, halfSize - 1)
            highBin = max(lowBin + 1, min(highBin, halfSize))

            var peak: Float = 0
            for bin in lowBin..<highBin {
                peak = max(peak, magnitudes[bin])
            }

            // Perceptual dB mapping keeps quiet speech visible without clipping loud music.
            let db = 20 * log10(max(peak * normalization, 1e-7))
            result[bar] = min(max((db - Self.floorDb) / dbRange, 0), 1)
        }
        return result
    }

    private func smooth(_ target: [Float], interval: TimeInterval) -> [Float] {
        guard smoothedBars.count == target.count else {
            smoothedBars = target
            return target
        }

        let frames = max(Float(interval) * 60, 0.0001)
        let attack = 1 - powf(1 - Self.attackPerFrame, frames)
        let release = 1 - powf(1 - Self.releasePerFrame, frames)

        var result = [Float](repeating: 0, count: target.count)
        for index in target.indices {
            let previous = smoothedBars[index]
            let coefficient = target[index] > previous ? attack : release
            var value = previous + (target[index] - previous) * coefficient
            if value < Self.visualFloor { value = 0 }
            result[index] = min(max(value, 0), 1)
        }
        smoothedBars = result
        return result
    }
}
