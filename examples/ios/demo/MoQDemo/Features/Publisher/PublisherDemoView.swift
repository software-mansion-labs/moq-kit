import SwiftUI
import MoQKit

struct PublisherDemoView: View {
    @State private var relayURL: String

    @State private var broadcastPath = "bbb/hey"
    @StateObject private var viewModel = PublisherViewModel()

    init(relayURL: String) {
        _relayURL = State(initialValue: relayURL)
    }

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
                PublisherConnectionControlsView(
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
                if viewModel.isPreviewRunning {
                    switch viewModel.cameraSourceMode {
                    case .singleCamera:
                        if let previewSession = viewModel.previewSession {
                            CameraPreviewView(session: previewSession)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .bottomTrailing) {
                                    if !isPublishing {
                                        Button(action: viewModel.flipCamera) {
                                            Image(systemName: "camera.rotate")
                                                .font(.title2)
                                                .padding(10)
                                                .background(.ultraThinMaterial)
                                                .clipShape(Circle())
                                        }
                                        .accessibilityLabel("Switch camera")
                                        .disabled(viewModel.isChangingMedia)
                                        .padding(12)
                                    }
                                }
                        }

                    case .multiCamera:
                        if let previewSession = viewModel.multiCameraPreviewSession {
                            MultiCameraPreviewView(
                                session: previewSession,
                                mainCameraPosition: viewModel.multiCameraMainPreviewPosition,
                                onSwap: viewModel.swapMultiCameraPreview
                            )
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                if isPublishing {
                    mediaControls
                } else {
                    SourceConfigView(
                        cameraEnabled: $viewModel.cameraEnabled,
                        cameraSourceMode: $viewModel.cameraSourceMode,
                        screenEnabled: $viewModel.screenEnabled,
                        micEnabled: $viewModel.micEnabled,
                        screenAudioEnabled: $viewModel.screenAudioEnabled,
                        cameraPosition: $viewModel.cameraPosition,
                        isPublishing: viewModel.isChangingMedia,
                        onFlipCamera: viewModel.flipCamera
                    )
                }

                if !isPublishing && !viewModel.isChangingMedia {
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
        .onChange(of: viewModel.cameraEnabled) {
            viewModel.handleCameraEnabledChanged()
        }
        .onChange(of: viewModel.cameraSourceMode) {
            viewModel.handleCameraSourceChanged()
        }
        .onDisappear {
            viewModel.stop()
            viewModel.stopPreview()
            PublisherViewModel.configurePlaybackAudioSession()
        }
        .navigationTitle("Publisher")
    }

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(spacing: 8) {
                    if viewModel.cameraSourceMode == .singleCamera {
                        mediaToggle("Camera", systemImage: "camera", isOn: viewModel.isCameraCapturing,
                                    action: viewModel.toggleCameraCapture)
                        Divider()
                    }
                    mediaToggle("Microphone", systemImage: "mic", isOn: viewModel.isMicrophoneCapturing,
                                action: viewModel.toggleMicrophoneCapture)
                    Divider()
                    mediaToggle("Mute microphone", systemImage: "mic.slash", isOn: viewModel.isMicrophoneMuted,
                                action: viewModel.toggleMicrophoneMute)
                        .tint(.orange)
                        .disabled(!viewModel.canMuteMicrophone)
                        .accessibilityHint("Sends silence while keeping the microphone active.")
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Capture")
                    Spacer()
                    if viewModel.cameraSourceMode == .singleCamera {
                        Button(action: viewModel.flipCamera) {
                            Label(viewModel.cameraPosition == .front ? "Front" : "Back", systemImage: "camera.rotate")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Switch camera")
                        .accessibilityValue(viewModel.cameraPosition == .front ? "Front" : "Back")
                    }
                }
            }

            GroupBox("Publication") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.publishedTracks.compactMap { $0 as? PublishedMediaTrack }, id: \.name) { track in
                        mediaToggle(
                            publicationTitle(for: track),
                            systemImage: publicationIcon(for: track),
                            isOn: viewModel.publicationEnabled[track.name] == true
                        ) {
                            viewModel.togglePublication(track)
                        }
                        .accessibilityLabel("Publish \(publicationTitle(for: track))")
                    }
                    Text("Turning publication off keeps capture and preview running. Enabled tracks resume when capture restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }

            if viewModel.isChangingMedia {
                ProgressView("Updating media…")
                    .font(.subheadline)
            }
        }
        .disabled(viewModel.isChangingMedia)
    }

    private func mediaToggle(
        _ title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { action() } })) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(title)
            }
            .font(.subheadline)
        }
        .frame(minHeight: 44)
    }

    private func publicationTitle(for track: PublishedMediaTrack) -> String {
        switch track.name {
        case "camera": return "Camera"
        case "front-camera": return "Front camera"
        case "back-camera": return "Back camera"
        case "mic": return "Microphone"
        default: return track.name
        }
    }

    private func publicationIcon(for track: PublishedMediaTrack) -> String {
        switch track.codecInfo {
        case .video: return "video"
        case .audio: return "waveform"
        case .data: return "dot.radiowaves.left.and.right"
        }
    }
}
