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
                if let info = viewModel.broadcastInfo {
                    if viewModel.broadcastOffline {
                        Text("Broadcast offline")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(info.videoTracks.first.map { "\($0.config.codec)" } ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let info = viewModel.broadcastInfo {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let video = info.videoTracks.first {
                            Text("Video: \(video.config.name) (\(video.config.codec))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let audio = info.audioTracks.first {
                            Text("Audio: \(audio.config.name) (\(audio.config.codec) \(audio.config.sampleRate) Hz)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            if let session = viewModel.session {
                VideoLayerView(layer: session.videoLayer)
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
