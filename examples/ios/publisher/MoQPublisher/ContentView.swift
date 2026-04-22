import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.140:4443/anon"

    @State private var broadcastPath = "bbb/hey"
    @StateObject private var viewModel = PublisherViewModel()

    private var isPublishing: Bool {
        if case .publishing = viewModel.publisherState { return true }
        return false
    }

    private var canConnect: Bool {
        !relayURL.isEmpty && !broadcastPath.isEmpty && viewModel.canPublish
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ConnectionControlsView(
                    relayURL: $relayURL,
                    broadcastPath: $broadcastPath,
                    canConnect: canConnect,
                    canStop: viewModel.canStop,
                    onConnect: {
                        viewModel.publish(url: relayURL, path: broadcastPath)
                    },
                    onStop: viewModel.stop
                )

                // Session status
                HStack {
                    Circle()
                        .fill(viewModel.stateColor)
                        .frame(width: 10, height: 10)
                    Text(viewModel.stateLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if viewModel.hasReplayKitTracks {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ReplayKit Broadcast")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        TextField("App Group ID", text: $viewModel.replayKitAppGroupIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .disabled(isPublishing)

                        TextField(
                            "Broadcast Extension Bundle ID (optional)",
                            text: $viewModel.replayKitExtensionBundleIdentifier
                        )
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(isPublishing)

                        Button("Prepare ReplayKit Config") {
                            viewModel.prepareReplayKitDescriptor(
                                url: relayURL,
                                path: broadcastPath
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPublishing)

                        HStack(spacing: 8) {
                            Text("Start System Broadcast")
                                .font(.subheadline)
                            ReplayKitBroadcastPickerButton(
                                preferredExtension: viewModel.replayKitExtensionBundleIdentifier
                                    .isEmpty
                                    ? nil : viewModel.replayKitExtensionBundleIdentifier
                            )
                            .frame(width: 44, height: 44)
                        }

                        Text(
                            "Use the system broadcast UI to stream full screen across app switches."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
                }

                // Camera preview
                if viewModel.cameraEnabled && viewModel.isPreviewRunning,
                    let previewSession = viewModel.previewSession
                {
                    CameraPreviewView(session: previewSession)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Button(action: viewModel.flipCamera) {
                                Image(systemName: "camera.rotate")
                                    .font(.title2)
                                    .padding(10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(12)
                        }
                }

                // Source configuration
                SourceConfigView(
                    cameraEnabled: $viewModel.cameraEnabled,
                    screenEnabled: $viewModel.screenEnabled,
                    micEnabled: $viewModel.micEnabled,
                    screenAudioEnabled: $viewModel.screenAudioEnabled,
                    cameraPosition: $viewModel.cameraPosition,
                    isPublishing: isPublishing,
                    onFlipCamera: viewModel.flipCamera
                )

                if !isPublishing {
                    CodecConfigView(
                        videoCodec: $viewModel.videoCodec,
                        videoResolution: $viewModel.videoResolution,
                        videoFrameRate: $viewModel.videoFrameRate,
                        audioCodec: $viewModel.audioCodec,
                        audioSampleRate: $viewModel.audioSampleRate
                    )
                }

                // Publishing status (when publishing)
                if isPublishing {
                    PublishingStatusView(
                        publisherState: viewModel.publisherState,
                        publisherStateLabel: viewModel.publisherStateLabel,
                        publisherStateColor: viewModel.publisherStateColor,
                        tracks: viewModel.publishedTracks,
                        trackStates: viewModel.trackStates,
                        lastError: viewModel.lastError
                    )
                }
            }
            .padding()
        }
        .onAppear {
            viewModel.startPreview()
        }
    }
}
