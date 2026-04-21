import MoQKit
import SwiftUI

struct SourceConfigView: View {
    @Binding var cameraEnabled: Bool
    @Binding var screenEnabled: Bool
    @Binding var micEnabled: Bool
    @Binding var screenAudioEnabled: Bool
    @Binding var cameraPosition: CameraPosition
    let isPublishing: Bool
    let onFlipCamera: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Video Sources
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Sources")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Toggle("Camera", isOn: $cameraEnabled)
                    .disabled(isPublishing)

                if cameraEnabled {
                    HStack(spacing: 8) {
                        Text("Position")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(cameraPosition == .front ? "Front" : "Back") {
                            onFlipCamera()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.leading, 4)
                }

                Toggle("Screen (ReplayKit)", isOn: $screenEnabled)
                    .disabled(isPublishing)
            }

            // Audio Sources
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Sources")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Toggle("Microphone", isOn: $micEnabled)
                    .disabled(isPublishing)

                Toggle("Screen Audio (ReplayKit)", isOn: $screenAudioEnabled)
                    .disabled(isPublishing)
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}
