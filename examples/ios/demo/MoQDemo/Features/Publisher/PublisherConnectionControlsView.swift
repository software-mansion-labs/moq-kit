import SwiftUI

struct PublisherConnectionControlsView: View {
    @Binding var relayURL: String
    @Binding var broadcastPath: String
    let canConnect: Bool
    let canStop: Bool
    let onConnect: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TextField("Relay URL", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            TextField("Broadcast Path", text: $broadcastPath)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            HStack(spacing: 12) {
                Button(action: onConnect) {
                    Label("Publish", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)

                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)
            }
        }
    }
}
