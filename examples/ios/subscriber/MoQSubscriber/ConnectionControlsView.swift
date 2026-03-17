import SwiftUI

struct ConnectionControlsView: View {
    @Binding var relayURL: String
    @Binding var broadcastPath: String
    @Binding var targetLatencyMs: Double
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

            VStack(spacing: 4) {
                HStack {
                    Text("Target Latency")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(targetLatencyMs)) ms")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $targetLatencyMs, in: 50...2000, step: 50)
            }

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
