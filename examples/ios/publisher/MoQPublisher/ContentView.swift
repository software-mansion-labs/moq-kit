import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.173:4443/anon"

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

                // Source configuration (when not publishing)
                if !isPublishing {
                    SourceConfigView(
                        cameraEnabled: $viewModel.cameraEnabled,
                        screenEnabled: $viewModel.screenEnabled,
                        micEnabled: $viewModel.micEnabled,
                        screenAudioEnabled: $viewModel.screenAudioEnabled,
                        cameraPosition: $viewModel.cameraPosition,
                        isPublishing: isPublishing,
                        onFlipCamera: viewModel.flipCamera
                    )

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
