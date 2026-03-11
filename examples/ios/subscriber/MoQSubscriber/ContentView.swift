import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.140:4443"
    @State private var broadcastPath = "anon/bbb/ccc"
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
    }

    private func connectAll() {
        player.connect(url: relayURL)
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
