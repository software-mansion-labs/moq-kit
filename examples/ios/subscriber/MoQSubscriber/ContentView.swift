import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.93.37:4443"
    @State private var broadcastPath = "bbb"
    @StateObject private var player = PlayerViewModel()

    private var canConnect: Bool {
        !relayURL.isEmpty && !broadcastPath.isEmpty && player.canConnect
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionControlsView(
                    relayURL: $relayURL,
                    broadcastPath: $broadcastPath,
                    canConnect: canConnect,
                    canStop: player.canStop,
                    onConnect: {
                        player.connect(url: relayURL)
                    },
                    onStop: player.stop
                )

                SessionPlayerView(viewModel: player)
            }
            .padding()
        }
    }
}
