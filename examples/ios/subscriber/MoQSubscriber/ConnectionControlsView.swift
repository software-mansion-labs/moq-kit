import SwiftUI

struct ConnectionControlsView: View {
    @Binding var relayURL: String
    @Binding var broadcastPath: String
    let canConnect: Bool
    let canStop: Bool
    let canPause: Bool
    let canResume: Bool
    let onConnect: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

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
                Button("Connect") { onConnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)

                Button("Stop") { onStop() }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)
                
                if canPause {
                    Button("Pause") { onPause() }
                        .buttonStyle(.bordered)
                } else if canResume {
                    Button("Resume") { onResume() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}
