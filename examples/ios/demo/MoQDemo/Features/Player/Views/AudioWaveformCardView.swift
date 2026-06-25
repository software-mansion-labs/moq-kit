import SwiftUI
import UIKit

struct AudioWaveformCardView: View {
    @ObservedObject var entry: BroadcastEntry
    @ObservedObject private var audioAnalysis: BroadcastAudioAnalysis

    init(entry: BroadcastEntry) {
        self.entry = entry
        self.audioAnalysis = entry.audioAnalysis
    }

    private var stateColor: Color {
        switch audioAnalysis.state {
        case .idle, .stopped:
            return .secondary
        case .starting:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var actionTitle: String {
        audioAnalysis.isActive ? "Stop" : "Start"
    }

    private var actionIcon: String {
        audioAnalysis.isActive ? "stop.fill" : "waveform"
    }

    private var isExpanded: Bool {
        audioAnalysis.isActive
    }

    private var compactStateLabel: String {
        if case .failed = audioAnalysis.state {
            return "error"
        }

        return audioAnalysis.state.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            HStack(spacing: 8) {
                Label("Audio Waveform", systemImage: "waveform")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)

                    Text(compactStateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    if audioAnalysis.isActive {
                        audioAnalysis.stop()
                    } else {
                        audioAnalysis.start(
                            catalog: entry.catalog,
                            track: entry.selectedAudioTrack,
                            targetLatencyMs: entry.targetLatencyMs
                        )
                    }
                } label: {
                    Label(actionTitle, systemImage: actionIcon)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(!entry.canStartAudioAnalysis && !audioAnalysis.isActive)
            }

            if isExpanded {
                ZStack {
                    FixedAudioWaveformView(samples: audioAnalysis.waveform.samples)

                    AudioWaveformDisplayLink(isActive: audioAnalysis.isActive) { displayInterval in
                        audioAnalysis.refreshWaveform(displayInterval: displayInterval)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .frame(height: 112)
                .transition(.opacity.combined(with: .move(edge: .top)))

                if let sampleRate = audioAnalysis.waveform.sampleRate,
                   let channelCount = audioAnalysis.waveform.channelCount
                {
                    Text("\(Int(sampleRate)) Hz / \(channelCount) ch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if case .failed(let message) = audioAnalysis.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

private struct AudioWaveformDisplayLink: UIViewRepresentable {
    let isActive: Bool
    let onFrame: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.onFrame = onFrame
        context.coordinator.update(isActive: isActive)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onFrame = onFrame
        context.coordinator.update(isActive: isActive)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        var onFrame: ((TimeInterval) -> Void)?
        private var displayLink: CADisplayLink?

        func update(isActive: Bool) {
            isActive ? start() : stop()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func start() {
            guard displayLink == nil else { return }

            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let maximumFramesPerSecond = max(UIScreen.main.maximumFramesPerSecond, 60)
            if #available(iOS 15.0, *) {
                let maximum = Float(maximumFramesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, maximum),
                    maximum: maximum,
                    preferred: maximum
                )
            } else {
                link.preferredFramesPerSecond = maximumFramesPerSecond
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            let displayInterval = link.targetTimestamp > link.timestamp
                ? link.targetTimestamp - link.timestamp
                : link.duration
            onFrame?(displayInterval > 0 ? displayInterval : 1.0 / 60.0)
        }
    }
}

private struct FixedAudioWaveformView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            drawWaveform(context: context, size: size)
        }
        .background(
            Color(red: 0.0, green: 0.11, blue: 0.16),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let barCount = max(samples.count, AudioWaveformSnapshot.barCount)
        guard barCount > 0, size.width > 0, size.height > 0 else { return }

        let spacing = max(3, size.width * 0.006)
        let availableWidth = max(0, size.width - spacing * CGFloat(barCount + 1))
        let barWidth = max(2, min(5, availableWidth / CGFloat(barCount)))
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = max(spacing, (size.width - totalWidth) / 2)
        let midY = size.height / 2
        let maxHeight = size.height * 0.78

        for index in 0..<barCount {
            let level = index < samples.count ? min(max(samples[index], 0), 1) : 0
            let barHeight = max(8, CGFloat(level) * maxHeight)
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(
                x: x,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            context.fill(path, with: .color(.white.opacity(samples.isEmpty ? 0.18 : 0.95)))
        }
    }
}
