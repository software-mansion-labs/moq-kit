import MoQKit
import SwiftUI

struct ContentView: View {
    @State private var relayURL = "http://192.168.92.140:4443"
    @State private var broadcastPath = "anon/bbb"
    @State private var session: MoQSession?
    @State private var sessionState: MoQSessionState = .idle
    @State private var broadcastInfo: MoQBroadcastInfo?
    @State private var broadcastOffline = false
    @State private var stateObserverTask: Task<Void, Never>?
    @State private var broadcastObserverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            TextField("Relay URL", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            TextField("Broadcast Path", text: $broadcastPath)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            HStack(spacing: 12) {
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)

                Button("Stop") { stop() }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)

                Button("Pause") { pause() }
                    .buttonStyle(.bordered)
            }

            HStack {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(stateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let info = broadcastInfo {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let video = info.videoTracks.first {
                            Text("Video: \(video.config.name) (\(video.config.codec))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let audio = info.audioTracks.first {
                            Text("Audio: \(audio.config.name) (\(audio.config.codec) \(audio.config.sampleRate) Hz)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if broadcastOffline {
                        Text("Broadcast offline")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let session {
                VideoLayerView(layer: session.videoLayer)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Text("No Video")
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Computed Properties

    private var canConnect: Bool {
        sessionState == .idle && !relayURL.isEmpty && !broadcastPath.isEmpty
    }

    private var canStop: Bool {
        sessionState == .connecting || sessionState == .connected || sessionState == .playing
    }

    private var stateLabel: String {
        switch sessionState {
        case .idle: return "idle"
        case .connecting: return "connecting..."
        case .connected: return "connected"
        case .playing: return "playing"
        case .error(let msg): return "error: \(msg)"
        case .closed: return "closed"
        }
    }

    private var stateColor: Color {
        switch sessionState {
        case .idle: return .gray
        case .connecting: return .orange
        case .connected: return .blue
        case .playing: return .green
        case .error: return .red
        case .closed: return .gray
        }
    }

    // MARK: - Actions

    private func connect() {
        let s = MoQSession(url: relayURL, path: broadcastPath)
        session = s

        stateObserverTask = Task {
            for await state in s.state {
                sessionState = state
            }
        }

        broadcastObserverTask = Task {
            for await event in s.broadcasts {
                switch event {
                case .available(let info):
                    broadcastInfo = info
                    broadcastOffline = false
                    
                    try? await s.startTrack(videoIndex: info.videoTracks.first?.index, audioIndex: info.audioTracks.first?.index)
                case .unavailable:
                    broadcastOffline = true
                }
            }
        }

        Task {
            do {
                try await s.connect()
            } catch {
                // State is already updated via the observer
            }
        }
    }

    private func stop() {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        broadcastObserverTask?.cancel()
        broadcastObserverTask = nil
        broadcastInfo = nil
        broadcastOffline = false
        let s = session
        session = nil
        sessionState = .idle
        Task { await s?.close() }
    }

    private func pause() {

    }
}
