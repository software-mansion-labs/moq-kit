import AVFoundation
import MoQKit
import SwiftUI

struct VideoPlayerView: View {
    @ObservedObject var entry: BroadcastEntry

    @State private var showControls = false
    @State private var isPaused = false
    @State private var isFullscreen = false
    @State private var videoLayerGeneration = 0
    @State private var hideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            videoContent

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            videoLayerGeneration += 1
        }) {
            FullscreenVideoView(entry: entry, isPaused: $isPaused)
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let layer = entry.videoLayer {
            VideoLayerView(layer: layer)
                .id(videoLayerGeneration)
        } else {
            Color.black
                .overlay {
                    if entry.offline {
                        Label("Broadcast Offline", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
        }
    }

    private var controlsOverlay: some View {
        ZStack {
            // Gradient scrim — non-interactive
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
            }
            .allowsHitTesting(false)

            // Pause/resume — centered
            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.black.opacity(0.4), in: Circle())
            }

            // Fullscreen button — bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        isFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func togglePlayPause() {
        if isPaused {
            Task { try? await entry.player?.play() }
            isPaused = false
        } else {
            Task { await entry.player?.pause() }
            isPaused = true
        }
        scheduleAutoHide()
    }
}

// MARK: - Fullscreen

private struct FullscreenVideoView: View {
    @ObservedObject var entry: BroadcastEntry
    @Binding var isPaused: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = false
    @State private var hideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let layer = entry.videoLayer {
                VideoLayerView(layer: layer).ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                .gesture(
                    DragGesture(minimumDistance: 50)
                        .onEnded { value in
                            if value.translation.height > 0 { dismiss() }
                        }
                )

            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .onAppear {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            }
        }
        .onDisappear {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    private var controlsOverlay: some View {
        ZStack {
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
            }
            .allowsHitTesting(false)

            // Pause/resume — centered
            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.black.opacity(0.4), in: Circle())
            }

            // Exit fullscreen — bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func togglePlayPause() {
        if isPaused {
            Task { try? await entry.player?.play() }
            isPaused = false
        } else {
            Task { await entry.player?.pause() }
            isPaused = true
        }
        scheduleAutoHide()
    }
}
