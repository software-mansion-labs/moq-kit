import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.161:4443"
    @State private var broadcastPath = "bbb"
    @State private var targetLatencyMs: Double = 200
    @StateObject private var player = PlayerViewModel()

    @State var paused: Bool = false
    @State private var latencyUpdateTask: Task<Void, Never>?

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

                SessionPlayerView(viewModel: player)
            }
            .padding()
        }
        .onChange(of: targetLatencyMs) {
            latencyUpdateTask?.cancel()
            latencyUpdateTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                player.updateTargetLatency(ms: UInt64(targetLatencyMs))
            }
        }
    }

    private func connectAll() {
        let latency = UInt64(targetLatencyMs)
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
