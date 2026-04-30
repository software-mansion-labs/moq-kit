import SwiftUI

private enum SubscriberDemo: String, CaseIterable, Hashable, Identifiable {
    case boy
    case chat
    case player

    var id: String { rawValue }

    var title: String {
        switch self {
        case .boy:
            return "Boy"
        case .chat:
            return "Chat"
        case .player:
            return "Player"
        }
    }

    var subtitle: String {
        switch self {
        case .boy:
            return "Game Boy-style demo with announced games, live playback, and viewer controls."
        case .chat:
            return "Publish and receive JSON chat messages over raw MoQ data tracks."
        case .player:
            return "Raw broadcast player with relay URL and prefix controls."
        }
    }

    var iconName: String {
        switch self {
        case .boy:
            return "figure.wave"
        case .chat:
            return "message.fill"
        case .player:
            return "play.rectangle.fill"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .boy:
            BoyDemoView()
        case .chat:
            ChatDemoView()
        case .player:
            PlayerDemoView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            DemoSelectionView()
                .navigationDestination(for: SubscriberDemo.self) { demo in
                    demo.destinationView
                }
        }
    }
}

private struct DemoSelectionView: View {
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subscriber Demo")
                        .font(.largeTitle.bold())
                    Text("Choose the demo mode you want to launch.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(SubscriberDemo.allCases) { demo in
                        NavigationLink(value: demo) {
                            DemoCardView(demo: demo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Demos")
    }
}

private struct DemoCardView: View {
    let demo: SubscriberDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: demo.iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text(demo.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(demo.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Text("Open Demo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
