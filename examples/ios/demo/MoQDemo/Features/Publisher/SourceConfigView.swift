import MoQKit
import SwiftUI

enum CameraSourceMode: String, CaseIterable, Identifiable {
    case singleCamera
    case multiCamera

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleCamera: return "Single Camera"
        case .multiCamera: return "MultiCam"
        }
    }
}

struct SourceConfigView: View {
    @Binding var cameraEnabled: Bool
    @Binding var cameraSourceMode: CameraSourceMode
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
                    Picker("Camera Source", selection: $cameraSourceMode) {
                        ForEach(CameraSourceMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                                .disabled(mode == .multiCamera && !MultiCameraCapture.isSupported)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isPublishing)

                    if cameraSourceMode == .singleCamera {
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
