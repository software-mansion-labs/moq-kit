import SwiftUI

struct PlayerDemoView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var relayURL: String
    @State private var broadcastPath = ""
    @StateObject private var player = PlayerDemoViewModel()

    init(relayURL: String) {
        _relayURL = State(initialValue: relayURL)
    }

    private var canConnect: Bool {
        !relayURL.isEmpty && player.canConnect
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
                        player.connect(url: relayURL, prefix: broadcastPath)
                    },
                    onStop: {
                        player.stop(reason: "stop button tapped")
                    }
                )

                SessionPlayerView(viewModel: player)
            }
            .padding()
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    player.stop(reason: "back button tapped")
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }
}
