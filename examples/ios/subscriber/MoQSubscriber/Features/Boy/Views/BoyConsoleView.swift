import SwiftUI

struct BoyConsoleView: View {
    @ObservedObject var viewModel: BoyDemoViewModel

    private let controlBaseWidth: CGFloat = 430
    private let controlBaseHeight: CGFloat = 190
    private let controlBaseSpacing: CGFloat = 18

    var body: some View {
        VStack(spacing: 28) {
            screenPanel

            GeometryReader { proxy in
                let scale = min(1, proxy.size.width / controlBaseWidth)
                let spacing = controlBaseSpacing * scale

                HStack(alignment: .bottom, spacing: spacing) {
                    BoyDirectionPad(
                        enabled: viewModel.controlsEnabled,
                        onPressChange: { control, isPressed in
                            viewModel.setButton(control, isPressed: isPressed)
                        }, scale: scale
                    )
                    .offset(x: -4 * scale, y: -28 * scale)

                    Spacer(minLength: 0)

                    BoyStartSelectCluster(
                        enabled: viewModel.controlsEnabled,
                        onPressChange: { control, isPressed in
                            viewModel.setButton(control, isPressed: isPressed)
                        }, scale: scale
                    )
                    .offset(x: -34 * scale, y: 18 * scale)

                    Spacer(minLength: 0)

                    BoyActionCluster(
                        enabled: viewModel.controlsEnabled,
                        onPressChange: { control, isPressed in
                            viewModel.setButton(control, isPressed: isPressed)
                        }, scale: scale
                    )
                    .offset(x: -120 * scale, y: -80 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: controlBaseHeight)

            HStack {
                Spacer(minLength: 0)
                BoySpeakerGrille()
            }
        }
        .padding(22)
        .frame(maxWidth: 460)
        .background(
            LinearGradient(
                colors: [Color.boyShellTop, Color.boyShellBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 34, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
    }

    private var screenPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color.boyIndicator)
                    .frame(width: 10, height: 10)

                Text("DOT MATRIX WITH STEREO SOUND")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer(minLength: 0)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.boyScreenFill)

                if let entry = viewModel.currentEntry {
                    BoyScreenPlayerView(entry: entry)
                        .id(entry.broadcastPath)
                } else {
                    BoyScreenPlaceholder(copy: viewModel.placeholderCopy)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
            }

            HStack {
                Text(viewModel.selectedGameName ?? "NO CARTRIDGE")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.boyLabel)

                Spacer(minLength: 0)

                Text("BOY")
                    .font(.headline.italic())
                    .foregroundStyle(Color.boyBrand)
            }
        }
        .padding(16)
        .background(
            Color.boyScreenBezel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct BoyScreenPlayerView: View {
    @ObservedObject var entry: BroadcastEntry

    var body: some View {
        ZStack {
            Color.black.opacity(0.15)

            if let layer = entry.videoLayer {
                VideoLayerView(layer: layer)
                    .overlay(alignment: .topTrailing) {
                        if entry.offline {
                            Label("Offline", systemImage: "wifi.slash")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                    }
            } else if entry.offline {
                BoyScreenPlaceholder(
                    copy: BoyScreenCopy(
                        title: "Broadcast offline",
                        subtitle: "The selected game stopped announcing on the relay."
                    )
                )
            } else {
                ProgressView()
                    .tint(Color.boyScreenInk)
                    .scaleEffect(1.2)
            }
        }
    }
}

private struct BoyScreenPlaceholder: View {
    let copy: BoyScreenCopy

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display")
                .font(.title2.weight(.semibold))
            Text(copy.title)
                .font(.headline.weight(.semibold))
            Text(copy.subtitle)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary.opacity(0.7))
        }
        .padding(24)
        .foregroundStyle(Color.boyScreenInk)
    }
}

private struct BoySpeakerGrille: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { _ in
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 4, height: 26)
                    .rotationEffect(.degrees(22))
            }
        }
        .padding(.trailing, 8)
    }
}
