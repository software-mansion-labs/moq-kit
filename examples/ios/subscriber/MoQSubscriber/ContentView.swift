import MoQKit
import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.140:4443"
    @State private var broadcastPath = "anon/bbb"
    @State private var player: MoQPlayer?
    @State private var playerState: MoQPlayerState = .idle
    @State private var stateObserverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            TextField("Relay URL", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            TextField("Broadcast Path", text: $broadcastPath)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            HStack(spacing: 12) {
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)

                Button("Stop") { stop() }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)
                
                Button("Pause") { pause() }
                    .buttonStyle(.bordered)
            }

            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(stateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let player {
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

            Spacer()
        }
        .padding()
    }

    // MARK: - Computed Properties

    private var canConnect: Bool {
        playerState == .idle && !relayURL.isEmpty && !broadcastPath.isEmpty
    }

    private var canStop: Bool {
        playerState == .connecting || playerState == .playing
    }

    private var stateLabel: String {
        switch playerState {
        case .idle: return "idle"
        case .connecting: return "connecting..."
        case .playing: return "playing"
        case .error(let msg): return "error: \(msg)"
        case .closed: return "closed"
        }
    }

    private var stateColor: Color {
        switch playerState {
        case .idle: return .gray
        case .connecting: return .orange
        case .playing: return .green
        case .error: return .red
        case .closed: return .gray
        }
    }

    // MARK: - Actions

    private func connect() {
        let p = MoQPlayer(url: relayURL, path: broadcastPath)
        player = p

        stateObserverTask = Task {
            for await state in p.state {
                playerState = state
            }
        }

        Task {
            do {
                try await p.play()
            } catch {
                // State is already updated via the observer
            }
        }
    }

    private func stop() {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        let p = player
        player = nil
        playerState = .idle
        Task { await p?.close() }
    }
    
    private func pause() {
        
    }
}
