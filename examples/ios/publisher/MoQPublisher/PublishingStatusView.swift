import MoQKit
import SwiftUI

struct PublishingStatusView: View {
    let publisherState: MoQPublisherState
    let publisherStateLabel: String
    let publisherStateColor: Color
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
            if !trackStates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracks")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    ForEach(trackStates.sorted(by: { $0.key < $1.key }), id: \.key) { name, state in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(trackStateColor(state))
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(trackStateLabel(state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }

            // Info pills
            HStack(spacing: 8) {
                InfoPill(text: "H.264")
                InfoPill(text: "1920x1080")
                InfoPill(text: "AAC 48kHz")
                Spacer()
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
