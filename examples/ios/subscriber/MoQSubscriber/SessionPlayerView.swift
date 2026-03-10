import SwiftUI

struct SessionPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 6) {
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Text("No Broadcasts")
                            .foregroundStyle(.white.opacity(0.5))
                    }
            } else {
                ForEach(viewModel.broadcasts) { entry in
                    BroadcastPlayerView(entry: entry)
                }
            }
        }
    }
}

private struct BroadcastPlayerView: View {
    @ObservedObject var entry: BroadcastEntry

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if entry.offline {
                    Text("Broadcast offline")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(entry.info.videoTracks.first.map { "\($0.config.codec)" } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let video = entry.info.videoTracks.first {
                        Text("Video: \(video.name) (\(video.config.codec))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let audio = entry.info.audioTracks.first {
                        Text("Audio: \(audio.name) (\(audio.config.codec) \(audio.config.sampleRate) Hz)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let player = entry.player {
                VideoLayerView(layer: player.videoLayer)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Text("No Video")
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
    }
}
