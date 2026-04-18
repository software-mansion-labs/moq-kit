import SwiftUI

struct BoyConsoleView: View {
    @ObservedObject var viewModel: BoyDemoViewModel

    @State private var showsBack = false
    @State private var showsGamePicker = false
    @State private var showsLatencyDialog = false
    @State private var carouselSelection: String?
    @State private var animatedInsertionGame: BoyGame?
    @State private var animatedInsertionOffset: CGFloat = 210
    @State private var animatedInsertionScale: CGFloat = 1

    private let controlBaseWidth: CGFloat = 430
    private let controlBaseHeight: CGFloat = 190
    private let controlBaseSpacing: CGFloat = 18
    private let consoleBodyHeight: CGFloat = 660

    var body: some View {
        VStack(spacing: 18) {
            topHardwareBar

            ZStack {
                frontFace
                    .opacity(showsBack ? 0 : 1)
                    .allowsHitTesting(!showsBack)

                backFace
                    .opacity(showsBack ? 1 : 0)
                    .allowsHitTesting(showsBack)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            .rotation3DEffect(
                .degrees(showsBack ? 180 : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showsBack)
        }
        .padding(.top, 28)
        .padding(.bottom, 30)
        .sheet(isPresented: $showsLatencyDialog) {
            BoyLatencySheet(
                latencyMs: $viewModel.targetLatencyMs,
                onChange: { latency in
                    viewModel.updateTargetLatency(ms: latency)
                }
            )
            .presentationDetents([.height(240)])
            .presentationDragIndicator(.visible)
        }
    }

    private var topHardwareBar: some View {
        HStack(spacing: 12) {
            BoyPowerSwitch(
                isOn: viewModel.canStop,
                isBusy: viewModel.isConnecting
            ) {
                if viewModel.canStop {
                    viewModel.stop()
                } else if viewModel.canConnect {
                    viewModel.connect()
                }
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    showsBack.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold))
                    Text(showsBack ? "Front" : "Back")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .textCase(.uppercase)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    LinearGradient(
                        colors: [Color.boyFlipButton, Color.boyBrand],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Capsule(style: .continuous)
                )
                .shadow(color: Color.boyBrand.opacity(0.26), radius: 10, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 460)
        .padding(.top, 8)
    }

    private var frontFace: some View {
        consoleBody {
            VStack(spacing: 26) {
                screenPanel

                GeometryReader { proxy in
                    let scale = min(1, proxy.size.width / controlBaseWidth)
                    let spacing = controlBaseSpacing * scale

                    HStack(alignment: .bottom, spacing: spacing) {
                        BoyDirectionPad(
                            enabled: viewModel.controlsEnabled,
                            onPressChange: { control, isPressed in
                                viewModel.setButton(control, isPressed: isPressed)
                            },
                            scale: scale
                        )
                        .offset(x: -4 * scale, y: -28 * scale)

                        Spacer(minLength: 0)

                        BoyStartSelectCluster(
                            enabled: viewModel.controlsEnabled,
                            onPressChange: { control, isPressed in
                                viewModel.setButton(control, isPressed: isPressed)
                            },
                            scale: scale
                        )
                        .offset(x: -34 * scale, y: 18 * scale)

                        Spacer(minLength: 0)

                        BoyActionCluster(
                            enabled: viewModel.controlsEnabled,
                            onPressChange: { control, isPressed in
                                viewModel.setButton(control, isPressed: isPressed)
                            },
                            scale: scale
                        )
                        .offset(x: -120 * scale, y: -80 * scale)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: controlBaseHeight)

                HStack {
                    Text("BOY")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.boyBrand)

                    Spacer(minLength: 0)

                    BoySpeakerGrille()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var backFace: some View {
        consoleBody {
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("BOY")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.boyBrand.opacity(0.78))
                        Spacer(minLength: 0)
                        Text("Model DMQ-01")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.boySubLabel)
                    }

                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.boyBackPanel.opacity(0.68))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        }
                        .overlay(alignment: .topLeading) {
                            Text("CARTRIDGE")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .kerning(1.3)
                                .foregroundStyle(Color.boySubLabel)
                                .padding(.top, 24)
                                .padding(.leading, 24)
                        }
                        .overlay {
                            BoyCartridgeDock(
                                title: viewModel.selectedGameName ?? "NO GAME INSERTED",
                                subtitle: cartridgeSubtitle,
                                isConnected: viewModel.isConnected,
                                isPickerOpen: showsGamePicker
                            ) {
                                openCartridgePicker()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 64)
                            .padding(.bottom, 24)
                        }
                        .frame(height: 290)

                    HStack(spacing: 12) {
                        BoyRearDetailPill(
                            label: "Catalog",
                            value: viewModel.games.isEmpty ? "Searching" : "\(viewModel.games.count)"
                        )
                        Button {
                            showsLatencyDialog = true
                        } label: {
                            BoyRearDetailPill(
                                label: "Latency",
                                value: viewModel.latencyLabel
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }

                    Text(
                        "Tap the cartridge lip to browse games, then flick through the cards and slide one into the slot."
                    )
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.boySubLabel)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                if showsGamePicker {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                                showsGamePicker = false
                            }
                        }

                    BoyCartridgeSelectorTray(
                        games: viewModel.games,
                        selection: $carouselSelection,
                        isConnected: viewModel.isConnected,
                        selectedGamePath: viewModel.selectedGamePath,
                        onEject: {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                                showsGamePicker = false
                            }
                            viewModel.selectGame(path: nil)
                        },
                        onInsert: { game in
                            insertCartridge(game)
                        }
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }

                if let animatedInsertionGame {
                    BoyFloatingCartridgeCard(title: animatedInsertionGame.name)
                        .scaleEffect(animatedInsertionScale)
                        .offset(y: animatedInsertionOffset)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
        }
    }

    private var screenPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                BoyBatteryIndicator(isConnected: viewModel.isConnected)
                    .padding(.top, 6)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 12) {
                    Text("DOT MATRIX WITH STEREO SOUND")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .kerning(1.1)
                        .foregroundStyle(.white.opacity(0.82))

                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(viewModel.isConnected ? Color.boyScreenFill : Color(.darkGray))

                        if let entry = viewModel.currentEntry {
                            BoyScreenPlayerView(entry: entry)
                                .id(entry.broadcastPath)
                        } else if viewModel.isConnected || viewModel.isConnecting {
                            BoyScreenPlaceholder(copy: viewModel.placeholderCopy)
                        } else {
                            EmptyView()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity)

                Color.clear
                    .frame(width: 28)
            }

            HStack(alignment: .center) {
                Text(viewModel.selectedGameName ?? "NO CARTRIDGE")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(Color.boyLabel)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let lastError = viewModel.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(
            Color.boyScreenBezel,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var cartridgeSubtitle: String? {
        if viewModel.selectedGameName != nil {
            return nil
        }
        if viewModel.isConnected {
            return viewModel.games.isEmpty ? "Scanning for cartridges..." : "Tap to select a game"
        }
        return "Power on to browse games"
    }

    private func openCartridgePicker() {
        carouselSelection = viewModel.selectedGamePath ?? viewModel.games.first?.broadcastPath
        withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
            showsGamePicker.toggle()
        }
    }

    private func insertCartridge(_ game: BoyGame) {
        carouselSelection = game.broadcastPath
        animatedInsertionGame = game
        animatedInsertionOffset = 210
        animatedInsertionScale = 1

        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            showsGamePicker = false
            animatedInsertionOffset = -78
            animatedInsertionScale = 0.34
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            viewModel.selectGame(path: game.broadcastPath)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            animatedInsertionGame = nil
            animatedInsertionOffset = 210
            animatedInsertionScale = 1
        }
    }

    @ViewBuilder
    private func consoleBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(22)
            .frame(maxWidth: 460, minHeight: consoleBodyHeight, maxHeight: consoleBodyHeight, alignment: .top)
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
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    .blur(radius: 0.4)
                    .padding(1)
            }
            .overlay(alignment: .topTrailing) {
                Capsule(style: .continuous)
                    .fill(Color.boyShellEdge.opacity(0.46))
                    .frame(width: 118, height: 7)
                    .padding(.top, 18)
                    .padding(.trailing, 22)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 12)
    }
}

private struct BoyPowerSwitch: View {
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("POWER")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(Color.boyLabel)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 82, height: 28)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isOn
                                    ? [Color.boyBatteryOn.opacity(0.75), Color.boyBatteryOn]
                                    : [Color.white.opacity(0.62), Color.boyShellEdge],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 22)
                        .padding(.horizontal, 4)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }

            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(
                Color.white.opacity(0.55),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct BoyBatteryIndicator: View {
    let isConnected: Bool

    var body: some View {
        Circle()
            .fill(isConnected ? Color.boyBatteryOn : Color.boyBatteryOff)
            .frame(width: 12, height: 12)
            .shadow(color: indicatorColor.opacity(isConnected ? 0.55 : 0.18), radius: 8, y: 0)
            .frame(width: 20)
    }

    private var indicatorColor: Color {
        isConnected ? .boyBatteryOn : .boyBatteryOff
    }
}

private struct BoyCartridgeDock: View {
    let title: String
    let subtitle: String?
    let isConnected: Bool
    let isPickerOpen: Bool
    let onTap: () -> Void

    private var hasCartridge: Bool {
        subtitle == nil
    }

    private var cartridgeColors: [Color] {
        BoyCartridgePalette.colors(for: hasCartridge ? title : nil)
    }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onTap) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.boySlot.opacity(0.46))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.black.opacity(0.10), lineWidth: 1)
                        }

                    
                    if hasCartridge {
                        BoyInsertedCartridgeLip(
                            title: title,
                            accentColors: cartridgeColors,
                            isConnected: isConnected
                        )
                        .padding(.top, 18)
                    } else {
                        BoyEmptyCartridgeSlot()
                            .padding(.top, 18)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 188)
            }
            .buttonStyle(.plain)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.boySubLabel)
            } else {
                Text(isPickerOpen ? "Tap away to close selector" : "Tap back here to browse cartridges")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.boySubLabel)
            }
        }
    }
}

private struct BoyEmptyCartridgeSlot: View {
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .frame(width: 236)
            .padding(.top, 2)

            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.22))
                .frame(width: 150, height: 6)
                .padding(.top, 40)
        }
    }
}

private struct BoyInsertedCartridgeLip: View {
    let title: String
    let accentColors: [Color]
    let isConnected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            BoyEmptyCartridgeSlot()

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: accentColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 186, height: 50)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 128, height: 22)
                    .overlay {
                        Text(title)
                            .font(
                                .system(
                                    size: 11.5,
                                    weight: .black,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Color.boyLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 10)
                    }
                    .padding(.top, 10)

                HStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(isConnected ? Color.boyBatteryOn : Color.boyBatteryOff)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 156)
                .padding(.top, 18)
            }
            .offset(y: -2)
            .mask(alignment: .top) {
                Rectangle()
                    .frame(width: 210, height: 30)
            }

        }
        .frame(width: 236, height: 60)
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}

private struct BoyCartridgeSelectorTray: View {
    let games: [BoyGame]
    @Binding var selection: String?
    let isConnected: Bool
    let selectedGamePath: String?
    let onEject: () -> Void
    let onInsert: (BoyGame) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Cartridge Wheel")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Color.boyLabel)

                Spacer(minLength: 0)

                if selectedGamePath != nil {
                    Button("Eject", role: .destructive, action: onEject)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }

            if games.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: isConnected ? "opticaldiscdrive" : "power")
                        .font(.title3.weight(.bold))
                    Text(isConnected ? "Waiting for games to appear" : "Power on to scan for games")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.boyLabel)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                TabView(selection: $selection) {
                    ForEach(games) { game in
                        BoyCarouselGameCard(
                            game: game,
                            isSelected: selection == game.broadcastPath
                        )
                        .padding(.horizontal, 30)
                        .tag(Optional(game.broadcastPath))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onInsert(game)
                        }
                    }
                }
                .frame(height: 192)
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

private struct BoyCarouselGameCard: View {
    let game: BoyGame
    let isSelected: Bool

    private var cartridgeColors: [Color] {
        BoyCartridgePalette.colors(for: game.name)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: cartridgeColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("BOY")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer(minLength: 0)
                        Circle()
                            .fill(Color.white.opacity(isSelected ? 0.95 : 0.42))
                            .frame(width: 10, height: 10)
                    }

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.90))
                        .overlay {
                            VStack(spacing: 8) {
                                Text(game.name)
                                    .font(.system(size: 20, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.boyLabel)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                                    .minimumScaleFactor(0.7)

                                Text("Tap to insert")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.boySubLabel)
                            }
                            .padding(18)
                        }
                }
                .padding(18)
            }
            .shadow(color: .black.opacity(isSelected ? 0.26 : 0.16), radius: isSelected ? 18 : 10, y: isSelected ? 10 : 6)
            .scaleEffect(isSelected ? 1 : 0.92)
            .padding(.vertical, isSelected ? 4 : 12)
    }
}

private struct BoyFloatingCartridgeCard: View {
    let title: String

    private var cartridgeColors: [Color] {
        BoyCartridgePalette.colors(for: title)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: cartridgeColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 170, height: 140)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.90))
                    .frame(width: 128, height: 82)
                    .overlay {
                        Text(title)
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(Color.boyLabel)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .padding(12)
                    }
            }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 10)
    }
}

private enum BoyCartridgePalette {
    static func colors(for name: String?) -> [Color] {
        guard let name else {
            return [Color.boyCartridge, Color.boyCartridgeDark]
        }

        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }

        let hue = Double(hash % 360) / 360.0
        let saturation = 0.42 + Double((hash >> 7) % 20) / 100.0
        let brightness = 0.56 + Double((hash >> 13) % 16) / 100.0

        let top = Color(
            hue: hue,
            saturation: min(0.82, saturation),
            brightness: min(0.86, brightness)
        )
        let bottom = Color(
            hue: hue,
            saturation: min(0.92, saturation + 0.14),
            brightness: max(0.24, brightness - 0.28)
        )

        return [top, bottom]
    }
}

private struct BoyRearDetailPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color.boySubLabel)
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.boyLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.45), in: Capsule(style: .continuous))
    }
}

private struct BoyLatencySheet: View {
    @Binding var latencyMs: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Target Latency")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Color.boyLabel)

            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(latencyMs)) ms")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.boyBrand)

                Spacer(minLength: 0)

                Text("50 ms steps")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.boySubLabel)
            }

            Slider(value: $latencyMs, in: 50...2000, step: 50)
                .tint(Color.boyBrand)

            Text("Adjusts the active game immediately and also applies to the next cartridge you start.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.boySubLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .presentationBackground(.thinMaterial)
        .onChange(of: latencyMs) { _, value in
            onChange(value)
        }
    }
}

private struct BoyScreenPlayerView: View {
    @ObservedObject var entry: BroadcastEntry

    var body: some View {
        ZStack {
            (entry.videoLayer == nil && !entry.offline ? Color(.darkGray) : Color.black.opacity(0.15))

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
                Color(.darkGray)
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
