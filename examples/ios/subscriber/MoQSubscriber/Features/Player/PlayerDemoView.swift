import SwiftUI

struct PlayerDemoView: View {
    @Environment(\.dismiss) private var dismiss

    // @State private var relayURL = "https://moq.fishjam.work"
    @State private var relayURL = "http://192.168.92.140:4443/anon"
    @State private var broadcastPath = ""
    @StateObject private var player = PlayerDemoViewModel()

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
                        player.connect(url: relayURL, prefix: broadcastPath)
                    },
                    onStop: player.stop
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
                    player.stop()
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }
}
