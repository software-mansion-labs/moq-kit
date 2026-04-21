import MoQKit
import SwiftUI

struct PublishingStatusView: View {
    let publisherState: MoQPublisherState
    let publisherStateLabel: String
    let publisherStateColor: Color
    let tracks: [MoQPublishedTrack]
    let trackStates: [String: MoQPublishedTrackState]
    let lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Publisher state
            HStack(spacing: 6) {
                Circle()
                    .fill(publisherStateColor)
                    .frame(width: 8, height: 8)
                Text(publisherStateLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            // Per-track status
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracks")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    ForEach(tracks.sorted(by: { $0.name < $1.name }), id: \.name) { track in
                        let state = trackStates[track.name] ?? .idle
                        HStack(spacing: 6) {
                            Circle()
                                .fill(trackStateColor(state))
                                .frame(width: 6, height: 6)
                            Text(track.name)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(trackStateLabel(state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ForEach(codecPills(for: track.codecInfo), id: \.self) { pill in
                                InfoPill(text: pill)
                            }
                        }
                    }
                }
            }

            // Error
            if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func trackStateColor(_ state: MoQPublishedTrackState) -> Color {
        switch state {
        case .idle: return .gray
        case .starting: return .orange
        case .active: return .green
        case .stopped: return .red
        }
    }

    private func trackStateLabel(_ state: MoQPublishedTrackState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .active: return "active"
        case .stopped: return "stopped"
        }
    }

    private func codecPills(for info: MoQTrackCodecInfo) -> [String] {
        switch info {
        case .video(let codec, let width, let height, let frameRate):
            let codecName: String
            switch codec {
            case .h264: codecName = "H.264"
            case .h265: codecName = "H.265"
            }
            let frameRateInt = Int(frameRate)
            return [codecName, "\(width)x\(height)@\(frameRateInt)"]
        case .audio(let codec, let sampleRate):
            let codecName: String
            switch codec {
            case .aac: codecName = "AAC"
            case .opus: codecName = "Opus"
            }
            let sampleRateKHz = Int(sampleRate / 1000)
            return ["\(codecName) \(sampleRateKHz)kHz"]
        case .data:
            return []
        }
            
    }
}

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
