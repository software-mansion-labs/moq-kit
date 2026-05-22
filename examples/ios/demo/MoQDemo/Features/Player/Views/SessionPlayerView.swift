import MoQKit
import SwiftUI

private extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
    }
}

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
                Text(entry.catalog.path)
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
                        if let audio = entry.selectedAudioTrack {
                            InfoPill(text: "\(audio.config.codec) \(audio.config.sampleRate) Hz")
                        }
                        Spacer()
                    }
                }

                // Rendition picker
                if entry.catalog.playableVideoTracks.count > 1 {
                    RenditionPickerView(
                        tracks: entry.catalog.playableVideoTracks,
                        selected: entry.selectedVideoTrack,
                        onSelect: { entry.switchVideoTrack(to: $0.name) }
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

                if entry.player != nil {
                    DiagnosticsCardView(entry: entry)
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

// MARK: - Diagnostics Card

private struct DiagnosticsCardView: View {
    @ObservedObject var entry: BroadcastEntry
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("Stats for Nerds", systemImage: "waveform.path.ecg")
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

                VStack(spacing: 12) {
                    startupSection
                    selectedTracksSection
                    if let stats = entry.playbackStats {
                        liveStatsSections(stats)
                    } else {
                        StatsSection(title: "Live") {
                            StatRow(label: "Playback samples", value: "pending", color: .secondary)
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
            if let ms = entry.startupDiagnostics.playRequestToPlaybackStartMs {
                Text("start \(formatMs(ms))")
                    .foregroundStyle(.secondary)
            }
            if let latency = entry.playbackStats?.videoLatency {
                Text(formatMs(latency))
                    .foregroundStyle(latencyColor(latency))
            }
            if let fps = entry.playbackStats?.videoFps {
                Text(formatFps(fps))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var startupSection: some View {
        let startup = entry.startupDiagnostics
        StatsSection(title: "Startup") {
            if let ms = startup.initToPlayRequestMs {
                StatRow(label: "Init -> play request", value: formatMs(ms))
            } else {
                StatRow(label: "Init -> play request", value: "pending", color: .secondary)
            }
            if let ms = startup.playRequestToPlaybackStartMs {
                StatRow(label: "Play request -> playback", value: formatMs(ms), color: startupColor(ms))
            } else if startup.playRequestedAtMs != nil {
                StatRow(label: "Play request -> playback", value: "pending", color: .secondary)
            }
            if let kind = startup.playbackStartedByKind {
                StatRow(label: "Playback start trigger", value: kind)
            }
            if let stats = entry.playbackStats {
                if let ms = stats.timeToFirst.videoFrame {
                    StatRow(label: "Play request -> video playable", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = stats.timeToFirst.audioFrame {
                    StatRow(label: "Play request -> audio playable", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = stats.timeToFirst.videoPlaying {
                    StatRow(label: "Play request -> video playing", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = stats.timeToFirst.audioPlaying {
                    StatRow(label: "Play request -> audio playing", value: formatMs(ms), color: startupColor(ms))
                }
            }
        }

        if !startup.orderedTracks.isEmpty {
            StatsSection(title: "Track Lifecycle") {
                ForEach(startup.orderedTracks) { track in
                    TrackStartupView(
                        track: track,
                        playRequestedAtMs: startup.playRequestedAtMs,
                        formatMs: formatMs,
                        startupColor: startupColor
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var selectedTracksSection: some View {
        if entry.selectedVideoTrack != nil || entry.selectedAudioTrack != nil {
            StatsSection(title: "Selected Tracks") {
                if let video = entry.selectedVideoTrack {
                    StatRow(label: "Video track", value: trackLabel(video.name))
                    StatRow(label: "Video codec", value: video.config.codec)
                    if let coded = video.config.coded {
                        StatRow(label: "Video coded size", value: "\(coded.width)x\(coded.height)")
                    }
                    if let framerate = video.config.framerate {
                        StatRow(label: "Declared frame rate", value: formatFps(framerate))
                    }
                    if let bitrate = video.config.bitrate {
                        StatRow(label: "Declared video bitrate", value: formatBitsPerSecond(bitrate))
                    }
                }
                if let audio = entry.selectedAudioTrack {
                    StatRow(label: "Audio track", value: trackLabel(audio.name))
                    StatRow(label: "Audio codec", value: audio.config.codec)
                    StatRow(label: "Audio format", value: "\(audio.config.sampleRate) Hz / \(audio.config.channelCount) ch")
                    if let bitrate = audio.config.bitrate {
                        StatRow(label: "Declared audio bitrate", value: formatBitsPerSecond(bitrate))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveStatsSections(_ stats: PlaybackStats) -> some View {
        if stats.videoLatency != nil || stats.audioLatency != nil {
            StatsSection(title: "Latency") {
                if let ms = stats.videoLatency {
                    StatRow(label: "Video live latency", value: formatMs(ms), color: latencyColor(ms))
                }
                if let ms = stats.audioLatency {
                    StatRow(label: "Audio live latency", value: formatMs(ms), color: latencyColor(ms))
                }
            }
        }

        if stats.audioRingBuffer != nil || stats.videoJitterBuffer != nil {
            StatsSection(title: "Buffers") {
                if let ms = stats.videoJitterBuffer {
                    StatRow(label: "Video jitter buffer", value: formatMs(ms), color: bufferColor(ms))
                }
                if let ms = stats.audioRingBuffer {
                    StatRow(label: "Audio ring buffer", value: formatMs(ms), color: bufferColor(ms))
                }
                StatRow(label: "Target buffer", value: formatMs(entry.targetLatencyMs))
            }
        }

        if stats.videoBitrateKbps != nil || stats.audioBitrateKbps != nil || stats.videoFps != nil {
            StatsSection(title: "Throughput") {
                if let kbps = stats.videoBitrateKbps {
                    StatRow(label: "Video bitrate", value: formatBitrate(kbps))
                }
                if let kbps = stats.audioBitrateKbps {
                    StatRow(label: "Audio bitrate", value: formatBitrate(kbps))
                }
                if let fps = stats.videoFps {
                    StatRow(label: "Displayed frame rate", value: formatFps(fps))
                }
            }
        }

        if stats.videoSwitches != nil || stats.audioSwitches != nil {
            StatsSection(title: "Track Switches") {
                if let switches = stats.videoSwitches {
                    TrackSwitchStatsView(
                        kind: "Video",
                        switches: switches,
                        formatMs: formatMs,
                        startupColor: startupColor
                    )
                }
                if let switches = stats.audioSwitches {
                    TrackSwitchStatsView(
                        kind: "Audio",
                        switches: switches,
                        formatMs: formatMs,
                        startupColor: startupColor
                    )
                }
            }
        }

        if hasHealthStats(stats) {
            StatsSection(title: "Health") {
                if let s = stats.videoStalls {
                    StatRow(label: "Video stalls", value: formatStalls(s), color: stallColor(s))
                }
                if let s = stats.audioStalls {
                    StatRow(label: "Audio stalls", value: formatStalls(s), color: stallColor(s))
                }
                if let d = stats.videoFramesDropped {
                    StatRow(label: "Video frames dropped", value: "\(d)", color: d > 0 ? .red : .primary)
                }
                if let d = stats.audioFramesDropped {
                    StatRow(label: "Audio frames dropped", value: "\(d)", color: d > 0 ? .red : .primary)
                }
            }
        }

        if stats.videoArrival != nil || stats.audioArrival != nil {
            StatsSection(title: "Frame Arrival") {
                if let arrival = stats.videoArrival {
                    ArrivalStatsView(kind: "Video", arrival: arrival)
                }
                if let arrival = stats.audioArrival {
                    ArrivalStatsView(kind: "Audio", arrival: arrival)
                }
            }
        }
    }

    private func hasHealthStats(_ stats: PlaybackStats) -> Bool {
        stats.videoStalls != nil
            || stats.audioStalls != nil
            || stats.videoFramesDropped != nil
            || stats.audioFramesDropped != nil
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 150 { return .green }
        if ms < 500 { return .orange }
        return .red
    }

    private func latencyColor(_ duration: Duration) -> Color {
        latencyColor(duration.milliseconds)
    }

    private func startupColor(_ ms: Double) -> Color {
        if ms < 250 { return .green }
        if ms < 1000 { return .orange }
        return .red
    }

    private func startupColor(_ duration: Duration) -> Color {
        startupColor(duration.milliseconds)
    }

    private func bufferColor(_ ms: Double) -> Color {
        let target = entry.targetLatencyMs
        if ms < target * 0.25 { return .orange }
        if ms > target * 2 { return .orange }
        return .primary
    }

    private func bufferColor(_ duration: Duration) -> Color {
        bufferColor(duration.milliseconds)
    }

    private func stallColor(_ stats: StallStats) -> Color {
        stats.count > 0 ? .orange : .primary
    }

    private func formatMs(_ ms: Double) -> String {
        if ms >= 1000 {
            return String(format: "%.2f s", ms / 1000)
        }
        return "\(Int(ms.rounded())) ms"
    }

    private func formatMs(_ duration: Duration) -> String {
        formatMs(duration.milliseconds)
    }

    private func formatBitrate(_ kbps: Double) -> String {
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000)
        }
        return "\(Int(kbps)) kbps"
    }

    private func formatBitsPerSecond(_ bps: UInt64) -> String {
        formatBitrate(Double(bps) / 1000)
    }

    private func formatFps(_ fps: Double) -> String {
        if fps >= 10 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.1f fps", fps)
    }

    private func formatStalls(_ stats: StallStats) -> String {
        "\(stats.count) / \(formatMs(stats.totalDuration)) / \(formatPercent(stats.rebufferingRatio))"
    }

    private func formatPercent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private func trackLabel(_ value: String) -> String {
        value.isEmpty ? "unnamed" : value
    }
}

// MARK: - Stats Helpers

private struct TrackStartupView: View {
    let track: TrackStartupDiagnostics
    let playRequestedAtMs: Double?
    let formatMs: (Double) -> String
    let startupColor: (Double) -> Color

    private var title: String {
        track.isTrackSwitch ? "\(track.kind.capitalized) switch" : "\(track.kind.capitalized) startup"
    }

    private var status: (text: String, color: Color) {
        if track.errorAtMs != nil { return ("error", .red) }
        if track.activeAtMs != nil { return ("active", .green) }
        if track.playingAtMs != nil { return ("playing", .green) }
        if track.readyAtMs != nil { return ("ready", .green) }
        if track.subscribeStartedAtMs != nil { return ("subscribing", .orange) }
        return ("pending", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(status.text)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.14), in: Capsule())
                    .foregroundStyle(status.color)
                Spacer()
            }
            if let trackName = track.trackName {
                StatRow(label: "Track", value: trackName)
            }
            if track.isTrackSwitch {
                if let ms = track.operationToReadyMs(playRequestedAtMs: playRequestedAtMs) {
                    StatRow(label: "Switch -> ready", value: formatMs(ms), color: startupColor(ms))
                } else if track.subscribeStartedAtMs != nil, track.errorAtMs == nil {
                    StatRow(label: "Switch -> ready", value: "pending", color: .secondary)
                }
            } else {
                if let ms = track.subscribeToReadyMs() {
                    StatRow(label: "Subscribe -> ready", value: formatMs(ms), color: startupColor(ms))
                } else if track.subscribeStartedAtMs != nil, track.errorAtMs == nil {
                    StatRow(label: "Subscribe -> ready", value: "pending", color: .secondary)
                }
                if let ms = track.operationToReadyMs(playRequestedAtMs: playRequestedAtMs) {
                    StatRow(label: "Play request -> ready", value: formatMs(ms), color: startupColor(ms))
                }
            }
            if let ms = track.readyToPlayingMs() {
                StatRow(label: "Ready -> playing", value: formatMs(ms), color: startupColor(ms))
            }
            if let ms = track.operationToPlayingMs(playRequestedAtMs: playRequestedAtMs) {
                StatRow(label: "\(track.operationLabel) -> playing", value: formatMs(ms), color: startupColor(ms))
            }
            if let ms = track.operationToActiveMs(playRequestedAtMs: playRequestedAtMs) {
                StatRow(label: "\(track.operationLabel) -> active", value: formatMs(ms), color: startupColor(ms))
            }
            if let errorMessage = track.errorMessage {
                StatRow(label: "Error", value: errorMessage, color: .red)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TrackSwitchStatsView: View {
    let kind: String
    let switches: TrackSwitchStats
    let formatMs: (Duration) -> String
    let startupColor: (Duration) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind)
                .font(.caption)
                .fontWeight(.medium)
            StatRow(label: "Switches", value: "\(switches.completedCount) / \(switches.requestedCount)")
            if let latest = switches.latest {
                if let trackName = latest.trackName {
                    StatRow(label: "Latest track", value: trackName)
                }
                StatRow(
                    label: "Latest status",
                    value: latestStatus(latest),
                    color: latestStatusColor(latest)
                )
                if let ms = latest.switchToReady {
                    StatRow(label: "Switch -> ready", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = latest.readyToPlaying {
                    StatRow(label: "Ready -> playing", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = latest.switchToPlaying {
                    StatRow(label: "Switch -> playing", value: formatMs(ms), color: startupColor(ms))
                }
                if let ms = latest.switchToActive {
                    StatRow(label: "Switch -> active", value: formatMs(ms), color: startupColor(ms))
                }
                if let errorMessage = latest.errorMessage {
                    StatRow(label: "Error", value: errorMessage, color: .red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func latestStatus(_ latest: TrackSwitch) -> String {
        if latest.errorMessage != nil { return "error" }
        if latest.isCompleted { return "active" }
        if latest.switchToPlaying != nil { return "playing" }
        if latest.switchToReady != nil { return "ready" }
        return "pending"
    }

    private func latestStatusColor(_ latest: TrackSwitch) -> Color {
        if latest.errorMessage != nil { return .red }
        if latest.isCompleted || latest.switchToPlaying != nil || latest.switchToReady != nil {
            return .green
        }
        return .orange
    }
}

private struct ArrivalStatsView: View {
    let kind: String
    let arrival: FrameArrivalStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind)
                .font(.caption)
                .fontWeight(.medium)
            if let fps = arrival.receivedFramesPerSecond {
                StatRow(label: "Received rate", value: formatFps(fps))
            }
            if let average = arrival.averageInterarrival {
                StatRow(label: "Average interarrival", value: formatMs(average))
            }
            if let max = arrival.maxInterarrival {
                StatRow(label: "Max interarrival", value: formatMs(max))
            }
            StatRow(label: "Slow arrivals", value: "\(arrival.slowArrivalCount)", color: arrival.slowArrivalCount > 0 ? .orange : .primary)
            StatRow(label: "Fast arrivals", value: "\(arrival.fastArrivalCount)", color: arrival.fastArrivalCount > 0 ? .orange : .primary)
            StatRow(label: "Out of order", value: outOfOrderValue, color: arrival.outOfOrderCount > 0 ? .red : .primary)
            StatRow(label: "Discontinuities", value: discontinuityValue, color: arrival.discontinuityCount > 0 ? .orange : .primary)
        }
        .padding(.vertical, 2)
    }

    private var outOfOrderValue: String {
        guard let delta = arrival.maxOutOfOrderDelta else {
            return "\(arrival.outOfOrderCount)"
        }
        return "\(arrival.outOfOrderCount) / max \(formatMs(delta))"
    }

    private var discontinuityValue: String {
        guard let gap = arrival.maxDiscontinuityGap else {
            return "\(arrival.discontinuityCount)"
        }
        return "\(arrival.discontinuityCount) / max \(formatMs(gap))"
    }

    private func formatMs(_ ms: Double) -> String {
        if ms >= 1000 {
            return String(format: "%.2f s", ms / 1000)
        }
        return "\(Int(ms.rounded())) ms"
    }

    private func formatMs(_ duration: Duration) -> String {
        formatMs(duration.milliseconds)
    }

    private func formatFps(_ fps: Double) -> String {
        if fps >= 10 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.1f fps", fps)
    }
}

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
    let tracks: [VideoTrackInfo]
    let selected: VideoTrackInfo?
    let onSelect: (VideoTrackInfo) -> Void

    private var sortedTracks: [VideoTrackInfo] {
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

    private func renditionLabel(_ track: VideoTrackInfo) -> String {
        if let h = track.config.coded?.height {
            return "\(h)p"
        }
        return track.name
    }
}
