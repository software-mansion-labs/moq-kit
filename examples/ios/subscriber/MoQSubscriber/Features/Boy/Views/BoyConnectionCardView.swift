import SwiftUI

struct BoyConnectionCardView: View {
    @ObservedObject var viewModel: BoyDemoViewModel
    let onOpenConsole: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BoyStateBadge(
                    text: viewModel.stateLabel,
                    color: viewModel.stateColor
                )

                if viewModel.canConnect {
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Disconnect") {
                        viewModel.stop()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Game")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boyLabel)

                Menu {
                    Button(viewModel.gamePickerPlaceholder) {
                        viewModel.selectGame(path: nil)
                    }
                    .disabled(!viewModel.canSelectGame)

                    ForEach(viewModel.games) { game in
                        Button(game.name) {
                            viewModel.selectGame(path: game.broadcastPath)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(viewModel.selectedGameName ?? viewModel.gamePickerPlaceholder)
                            .foregroundStyle(viewModel.selectedGameName == nil ? Color.boyLabel.opacity(0.8) : Color.boyLabel)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.boyLabel.opacity(0.8))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                }
                .disabled(!viewModel.canSelectGame)
            }
            .frame(maxWidth: .infinity)

            Button("Open Console") {
                viewModel.openConsole()
                onOpenConsole()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canOpenConsole)

            if let viewerId = viewModel.viewerId {
                Text("Viewer: \(viewerId)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let lastError = viewModel.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

struct BoyStateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}
