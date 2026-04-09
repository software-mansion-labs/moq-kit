import SwiftUI

struct ContentView: View {
    // @State private var relayURL = "http://192.168.92.140:4443"
    @State private var relayURL = "https://cdn.moq.dev/demo?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb290IjoiZGVtbyIsImdldCI6WyIiXSwiZXhwIjpudWxsLCJpYXQiOm51bGx9.6EoN-Y1Ouj35_qV5FokcdcdderrE2navNbYQjJyR2Ac"
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
