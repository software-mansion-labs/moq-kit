import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.228:4443"
    @State private var broadcastPath = "bbb"
    @State private var targetLatencyMs = "200"
    @StateObject private var player = PlayerViewModel()

    @State var paused: Bool = false

    private var canConnect: Bool {
        !relayURL.isEmpty && !broadcastPath.isEmpty && player.canConnect
    }

    private var canStop: Bool {
        player.canStop
    }

    private var canPause: Bool {
        !paused
    }

    private var canResume: Bool {
        paused
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionControlsView(
                    relayURL: $relayURL,
                    broadcastPath: $broadcastPath,
                    targetLatencyMs: $targetLatencyMs,
                    canConnect: canConnect,
                    canStop: canStop,
                    canPause: canPause,
                    canResume: canResume,
                    onConnect: connectAll,
                    onStop: stopAll,
                    onPause: pauseAll,
                    onResume: resumeAll
                )

                Picker("Player", selection: $player.playerType) {
                    ForEach(PlayerType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!player.canConnect)

                SessionPlayerView(viewModel: player)
            }
            .padding()
        }
    }

    private func connectAll() {
        let latency = UInt64(targetLatencyMs) ?? 200
        player.connect(url: relayURL, targetLatencyMs: latency)
    }

    private func stopAll() {
        player.stop()
    }

    private func pauseAll() {
        paused = true
        player.pause()
    }

    private func resumeAll() {
        paused = false
        player.play()
    }
}
