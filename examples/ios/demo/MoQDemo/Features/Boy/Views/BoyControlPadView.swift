import CoreHaptics
import SwiftUI
import UIKit

struct BoyDirectionPad: View {
    let enabled: Bool
    let onPressChange: (BoyControl, Bool) -> Void
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.18))
                .frame(width: centerDiameter, height: centerDiameter)

            BoyRectControlButton(
                iconName: "chevron.up",
                enabled: enabled,
                scale: scale
            ) { isPressed in
                onPressChange(.up, isPressed)
            }
            .offset(y: -buttonOffset)

            BoyRectControlButton(
                iconName: "chevron.down",
                enabled: enabled,
                scale: scale
            ) { isPressed in
                onPressChange(.down, isPressed)
            }
            .offset(y: buttonOffset)

            BoyRectControlButton(
                iconName: "chevron.left",
                enabled: enabled,
                scale: scale
            ) { isPressed in
                onPressChange(.left, isPressed)
            }
            .offset(x: -buttonOffset)

            BoyRectControlButton(
                iconName: "chevron.right",
                enabled: enabled,
                scale: scale
            ) { isPressed in
                onPressChange(.right, isPressed)
            }
            .offset(x: buttonOffset)
        }
        .frame(width: padSize, height: padSize)
    }

    private var centerDiameter: CGFloat { 44 * scale }
    private var buttonOffset: CGFloat { 52 * scale }
    private var padSize: CGFloat { 160 * scale }
}

struct BoyActionCluster: View {
    let enabled: Bool
    let onPressChange: (BoyControl, Bool) -> Void
    var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: buttonSpacing) {
            actionButton(title: "B", control: .b, topPadding: lowerButtonYOffset)
            actionButton(title: "A", control: .a, topPadding: upperButtonYOffset)
        }
        .frame(width: clusterWidth, height: clusterHeight)
        .rotationEffect(.degrees(-18))
    }

    @ViewBuilder
    private func actionButton(title: String, control: BoyControl, topPadding: CGFloat) -> some View {
        VStack(spacing: 8 * scale) {
            BoyCircleControlButton(title: title, enabled: enabled, scale: scale) { isPressed in
                onPressChange(control, isPressed)
            }

            Text(title)
                .font(.system(size: 12 * scale, weight: .bold))
                .foregroundStyle(Color.boyActionLabel)
        }
        .padding(.top, topPadding)
    }

    private var lowerButtonYOffset: CGFloat { 28 * scale }
    private var upperButtonYOffset: CGFloat { 0 }
    private var buttonSpacing: CGFloat { 18 * scale }
    private var clusterWidth: CGFloat { 170 * scale }
    private var clusterHeight: CGFloat { 140 * scale }
}

struct BoyStartSelectCluster: View {
    let enabled: Bool
    let onPressChange: (BoyControl, Bool) -> Void
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 8 * scale) {
            HStack(spacing: spacing) {
                BoyCapsuleControlButton(enabled: enabled, scale: scale) { isPressed in
                    onPressChange(.select, isPressed)
                }

                BoyCapsuleControlButton(enabled: enabled, scale: scale) { isPressed in
                    onPressChange(.start, isPressed)
                }
            }

            HStack(spacing: labelSpacing) {
                Text("SELECT")
                Text("START")
            }
            .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
            .kerning(0.8 * scale)
            .foregroundStyle(Color.boyLabel.opacity(enabled ? 0.92 : 0.48))
        }
        .rotationEffect(.degrees(-24))
        .frame(width: clusterWidth, height: clusterHeight, alignment: .bottom)
    }

    private var spacing: CGFloat { 14 * scale }
    private var clusterWidth: CGFloat { 150 * scale }
    private var clusterHeight: CGFloat { 78 * scale }
    private var labelSpacing: CGFloat { 18 * scale }
}

private struct BoyRectControlButton: View {
    let iconName: String
    let enabled: Bool
    let scale: CGFloat
    let onPressChange: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: buttonColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: buttonSize, height: buttonSize)
            .overlay {
                Image(systemName: iconName)
                    .font(.system(size: 17 * scale, weight: .black))
                    .foregroundStyle(iconColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(pressedOutlineColor, lineWidth: isPressed ? max(2, 3 * scale) : max(1, 1.2 * scale))
            }
            .overlay {
                if isPressed, enabled {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .shadow(color: glowColor, radius: isPressed ? 10 * scale : 0, y: 0)
            .shadow(color: .black.opacity(isPressed ? 0.14 : 0.24), radius: isPressed ? 4 : 7, y: isPressed ? 2 : 5)
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.7)
            .gesture(pressGesture)
            .onDisappear {
                release()
            }
    }

    private var buttonSize: CGFloat { 58 * scale }
    private var iconColor: Color { .white.opacity(enabled ? (isPressed ? 1 : 0.95) : 0.55) }
    private var pressedOutlineColor: Color {
        guard enabled else { return Color.white.opacity(0.08) }
        return isPressed ? Color.white.opacity(0.75) : Color.white.opacity(0.14)
    }
    private var glowColor: Color {
        guard enabled, isPressed else { return .clear }
        return Color.white.opacity(0.22)
    }

    private var buttonColors: [Color] {
        if isPressed, enabled {
            return [.boyButtonPressedTop, .boyButtonPressedBottom]
        }
        if enabled {
            return [.boyButtonTop, .boyButtonBottom]
        }
        return [
            Color.black.opacity(0.25),
            Color.black.opacity(0.18)
        ]
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard enabled, !isPressed else { return }
                isPressed = true
                BoyButtonHaptics.shared.press()
                onPressChange(true)
            }
            .onEnded { _ in
                release()
            }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onPressChange(false)
    }
}

private struct BoyCircleControlButton: View {
    let title: String
    let enabled: Bool
    let scale: CGFloat
    let onPressChange: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: buttonColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: buttonDiameter, height: buttonDiameter)
            .overlay {
                Text(title)
                    .font(.system(size: 20 * scale, weight: .heavy))
                    .foregroundStyle(labelColor)
            }
            .overlay {
                Circle()
                    .strokeBorder(pressedOutlineColor, lineWidth: isPressed ? max(2, 3 * scale) : max(1, 1.2 * scale))
            }
            .overlay {
                if isPressed, enabled {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.22),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 2,
                                endRadius: buttonDiameter
                            )
                        )
                }
            }
            .shadow(color: glowColor, radius: isPressed ? 12 * scale : 0, y: 0)
            .shadow(color: .black.opacity(isPressed ? 0.14 : 0.24), radius: isPressed ? 4 : 8, y: isPressed ? 2 : 5)
            .scaleEffect(isPressed ? 0.95 : 1)
            .opacity(enabled ? 1 : 0.7)
            .gesture(pressGesture)
            .onDisappear {
                release()
            }
    }

    private var buttonDiameter: CGFloat { 72 * scale }
    private var labelColor: Color { .white.opacity(enabled ? (isPressed ? 1 : 0.97) : 0.55) }
    private var pressedOutlineColor: Color {
        guard enabled else { return Color.white.opacity(0.08) }
        return isPressed ? Color.white.opacity(0.8) : Color.white.opacity(0.16)
    }
    private var glowColor: Color {
        guard enabled, isPressed else { return .clear }
        return Color.boyIndicator.opacity(0.32)
    }

    private var buttonColors: [Color] {
        if isPressed, enabled {
            return [.boyActionPressedTop, .boyActionPressedBottom]
        }
        if enabled {
            return [.boyActionTop, .boyActionBottom]
        }
        return [.boyActionDisabledTop, .boyActionDisabledBottom]
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard enabled, !isPressed else { return }
                isPressed = true
                BoyButtonHaptics.shared.press()
                onPressChange(true)
            }
            .onEnded { _ in
                release()
            }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onPressChange(false)
    }
}

private struct BoyCapsuleControlButton: View {
    let enabled: Bool
    let scale: CGFloat
    let onPressChange: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: buttonColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: buttonWidth, height: buttonHeight)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(pressedOutlineColor, lineWidth: isPressed ? max(1.8, 2.5 * scale) : max(1, 1.1 * scale))
            }
            .shadow(color: .black.opacity(isPressed ? 0.12 : 0.22), radius: isPressed ? 3 : 6, y: isPressed ? 1 : 4)
            .scaleEffect(isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.7)
            .gesture(pressGesture)
            .onDisappear {
                release()
            }
    }

    private var buttonWidth: CGFloat { 60 * scale }
    private var buttonHeight: CGFloat { 18 * scale }
    private var pressedOutlineColor: Color {
        guard enabled else { return Color.white.opacity(0.06) }
        return isPressed ? Color.white.opacity(0.52) : Color.black.opacity(0.18)
    }

    private var buttonColors: [Color] {
        if isPressed, enabled {
            return [
                Color(red: 0.42, green: 0.43, blue: 0.49),
                Color(red: 0.20, green: 0.20, blue: 0.24)
            ]
        }
        return [
            Color(red: 0.55, green: 0.56, blue: 0.61),
            Color(red: 0.31, green: 0.32, blue: 0.37)
        ]
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard enabled, !isPressed else { return }
                isPressed = true
                BoyButtonHaptics.shared.press()
                onPressChange(true)
            }
            .onEnded { _ in
                release()
            }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onPressChange(false)
    }
}

private final class BoyButtonHaptics {
    static let shared = BoyButtonHaptics()

    private let engine: CHHapticEngine?
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)

    private init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            let engine = try? CHHapticEngine()
            engine?.isAutoShutdownEnabled = true
            self.engine = engine
        } else {
            self.engine = nil
        }

        fallback.prepare()
    }

    func press() {
        guard let engine else {
            fallback.impactOccurred(intensity: 1)
            fallback.prepare()
            return
        }

        do {
            try engine.start()

            let events = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.95),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.18)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.32),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05)
                    ],
                    relativeTime: 0.035
                )
            ]

            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            fallback.impactOccurred(intensity: 1)
        }

        fallback.prepare()
    }
}
