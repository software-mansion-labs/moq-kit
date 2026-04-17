import MoQKit
import SwiftUI

struct SessionPlayerView: View {
    @ObservedObject var viewModel: PlayerDemoViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(viewModel.stateColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.stateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if viewModel.broadcasts.isEmpty {
                VideoCardView {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            Text("No Broadcasts")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
            } else {
                ForEach(viewModel.broadcasts) { entry in
                    BroadcastPlayerView(entry: entry)
                }
            }
        }
    }
}

// MARK: - Video Card

private struct VideoCardView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            )
    }
}

// MARK: - Broadcast Player

private struct BroadcastPlayerView: View {
    @ObservedObject var entry: BroadcastEntry
    @State private var latencyUpdateTask: Task<Void, Never>?

    private var statusColor: Color {
        if entry.offline { return .red }
        if entry.isPaused { return .orange }
        if entry.isPlaying { return .green }
        return .orange
    }

    private var statusLabel: String {
        if entry.offline { return "offline" }
        if entry.isPaused { return "paused" }
        if entry.isPlaying { return "playing" }
        return "connecting"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(entry.info.path)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Video player
            if entry.player?.videoLayer != nil {
                VideoPlayerView(entry: entry)
                    .aspectRatio(16 / 9, contentMode: .fit)
            }

            VStack(spacing: 12) {
                // Track info pills
                if !entry.offline {
                    HStack(spacing: 8) {
                        if let video = entry.selectedVideoTrack {
                            InfoPill(text: video.config.codec)
                            if let size = video.config.coded {
                                InfoPill(text: "\(size.width)×\(size.height)")
                            }
                        }
                        if let audio = entry.info.audioTracks.first {
                            InfoPill(text: "\(audio.config.codec) \(audio.config.sampleRate) Hz")
                        }
                        Spacer()
                    }
                }

                // Rendition picker
                if entry.info.videoTracks.count > 1 {
                    RenditionPickerView(
                        tracks: entry.info.videoTracks,
                        selected: entry.selectedVideoTrack,
                        onSelect: { entry.switchVideoTrack(to: $0) }
                    )
                }

                // Target latency
                VStack(spacing: 4) {
                    HStack {
                        Text("Target Latency")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(entry.targetLatencyMs)) ms")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $entry.targetLatencyMs, in: 50...2000, step: 50)
                }
                .onChange(of: entry.targetLatencyMs) {
                    latencyUpdateTask?.cancel()
                    latencyUpdateTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        entry.updateTargetLatency(ms: UInt64(entry.targetLatencyMs))
                    }
                }

                // Expandable stats
                if let stats = entry.playbackStats {
                    StatsCardView(stats: stats)
                }
            }
            .padding(12)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - Info Pill

private struct InfoPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: Capsule())
    }
}

// MARK: - Stats Card

private struct StatsCardView: View {
    let stats: PlaybackStats
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Playback Stats", systemImage: "chart.bar.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    summaryView
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.vertical, 8)

                VStack(spacing: 10) {
                    // Latency section
                    if stats.videoLatencyMs != nil || stats.audioLatencyMs != nil {
                        StatsSection(title: "Latency") {
                            if let ms = stats.videoLatencyMs {
                                StatRow(
                                    label: "Video", value: "\(Int(ms)) ms", color: latencyColor(ms))
                            }
                            if let ms = stats.audioLatencyMs {
                                StatRow(
                                    label: "Audio", value: "\(Int(ms)) ms", color: latencyColor(ms))
                            }
                        }
                    }

                    // Buffers section
                    if stats.audioRingBufferMs != nil || stats.videoJitterBufferMs != nil {
                        StatsSection(title: "Buffers") {
                            if let ms = stats.videoJitterBufferMs {
                                StatRow(label: "Video jitter buffer", value: "\(Int(ms)) ms")
                            }
                            if let ms = stats.audioRingBufferMs {
                                StatRow(label: "Audio ring buffer", value: "\(Int(ms)) ms")
                            }
                        }
                    }

                    // Throughput section
                    if stats.videoBitrateKbps != nil || stats.audioBitrateKbps != nil
                        || stats.videoFps != nil
                    {
                        StatsSection(title: "Throughput") {
                            if let kbps = stats.videoBitrateKbps {
                                StatRow(label: "Video bitrate", value: formatBitrate(kbps))
                            }
                            if let kbps = stats.audioBitrateKbps {
                                StatRow(label: "Audio bitrate", value: formatBitrate(kbps))
                            }
                            if let fps = stats.videoFps {
                                StatRow(label: "Frame rate", value: "\(Int(fps)) fps")
                            }
                        }
                    }

                    // Startup section
                    if stats.timeToFirstVideoFrameMs != nil || stats.timeToFirstAudioFrameMs != nil
                    {
                        StatsSection(title: "Startup") {
                            if let ms = stats.timeToFirstVideoFrameMs {
                                StatRow(label: "First video frame", value: "\(Int(ms)) ms")
                            }
                            if let ms = stats.timeToFirstAudioFrameMs {
                                StatRow(label: "First audio frame", value: "\(Int(ms)) ms")
                            }
                        }
                    }

                    // Health section
                    if hasHealthStats {
                        StatsSection(title: "Health") {
                            if let s = stats.videoStalls, s.count > 0 {
                                StatRow(
                                    label: "Video stalls",
                                    value: "\(s.count) (\(Int(s.totalDurationMs)) ms)",
                                    color: .orange)
                            }
                            if let s = stats.audioStalls, s.count > 0 {
                                StatRow(
                                    label: "Audio stalls",
                                    value: "\(s.count) (\(Int(s.totalDurationMs)) ms)",
                                    color: .orange)
                            }
                            if let d = stats.videoFramesDropped, d > 0 {
                                StatRow(label: "Video frames dropped", value: "\(d)", color: .red)
                            }
                            if let d = stats.audioFramesDropped, d > 0 {
                                StatRow(label: "Audio frames dropped", value: "\(d)", color: .red)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    // Compact summary shown in the collapsed header
    @ViewBuilder
    private var summaryView: some View {
        HStack(spacing: 8) {
            if let ms = stats.videoLatencyMs {
                Text("\(Int(ms)) ms")
                    .foregroundStyle(latencyColor(ms))
            }
            if let fps = stats.videoFps {
                Text("\(Int(fps)) fps")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var hasHealthStats: Bool {
        (stats.videoStalls.map { $0.count > 0 } ?? false)
            || (stats.audioStalls.map { $0.count > 0 } ?? false)
            || (stats.videoFramesDropped.map { $0 > 0 } ?? false)
            || (stats.audioFramesDropped.map { $0 > 0 } ?? false)
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 150 { return .green }
        if ms < 500 { return .orange }
        return .red
    }

    private func formatBitrate(_ kbps: Double) -> String {
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000)
        }
        return "\(Int(kbps)) kbps"
    }
}

// MARK: - Stats Helpers

private struct StatsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Rendition Picker

private struct RenditionPickerView: View {
    let tracks: [MoQVideoTrackInfo]
    let selected: MoQVideoTrackInfo?
    let onSelect: (MoQVideoTrackInfo) -> Void

    private var sortedTracks: [MoQVideoTrackInfo] {
        tracks.sorted {
            ($0.config.coded.map { UInt64($0.width) * UInt64($0.height) } ?? 0)
                > ($1.config.coded.map { UInt64($0.width) * UInt64($0.height) } ?? 0)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(sortedTracks, id: \.name) { track in
                let isSelected = track.name == selected?.name
                Button(renditionLabel(track)) {
                    onSelect(track)
                }
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .disabled(isSelected)
            }
            Spacer()
        }
    }

    private func renditionLabel(_ track: MoQVideoTrackInfo) -> String {
        if let h = track.config.coded?.height {
            return "\(h)p"
        }
        return track.name
    }
}
