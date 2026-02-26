import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.140:4443"
    @State private var broadcastPath = "anon/bbb"
    @StateObject private var player = PlayerViewModel()

    private var canConnect: Bool {
        !relayURL.isEmpty && !broadcastPath.isEmpty && player.canConnect
    }

    private var canStop: Bool {
        player.canStop
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionControlsView(
                    relayURL: $relayURL,
                    broadcastPath: $broadcastPath,
                    canConnect: canConnect,
                    canStop: canStop,
                    onConnect: connectAll,
                    onStop: stopAll
                )

                SessionPlayerView(viewModel: player)
            }
            .padding()
        }
    }

    private func connectAll() {
        player.connect(url: relayURL, path: broadcastPath)
    }

    private func stopAll() {
        player.stop()
    }
}
