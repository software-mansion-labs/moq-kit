import MoQKit
import SwiftUI

@MainActor
final class BoyDemoViewModel: ObservableObject {
    static let relayURL = "https://cdn.moq.dev/demo"

    private static let subscribePrefix = "boy"
    private static let viewerPrefix = "viewer/boy"
    private static let repeatIntervalNs: UInt64 = 10_000_000
    private static let longPressThresholdNs: UInt64 = 300_000_000

    @Published private(set) var sessionState: MoQSessionState = .idle
    @Published private(set) var games: [BoyGame] = []
    @Published private(set) var currentEntry: BroadcastEntry?
    @Published private(set) var selectedGamePath: String?
    @Published private(set) var viewerId: String?
    @Published var lastError: String?

    private var session: MoQSession?
    private var announcedGames: [String: MoQBroadcastInfo] = [:]
    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?
    private var commandPublisher: MoQPublisher?
    private var commandEmitter: MoQObjectEmitter?
    private var viewerPath: String?
    private var heldButtons: Set<BoyButton> = []
    private var holdStartTimes: [BoyButton: UInt64] = [:]
    private var repeatTask: Task<Void, Never>?

    var canConnect: Bool {
        switch sessionState {
        case .idle, .error, .closed:
            return true
        default:
            return false
        }
    }

    var canStop: Bool {
        sessionState == .connecting || sessionState == .connected
    }

    var canSelectGame: Bool {
        sessionState == .connected && !games.isEmpty
    }

    var canOpenConsole: Bool {
        sessionState == .connected && selectedGamePath != nil
    }

    var controlsEnabled: Bool {
        currentEntry != nil && commandEmitter != nil
    }

    var selectedGameName: String? {
        games.first(where: { $0.broadcastPath == selectedGamePath })?.name
    }

    var stateLabel: String {
        switch sessionState {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .error(let message):
            return "error: \(message)"
        case .closed:
            return "closed"
        }
    }

    var stateColor: Color {
        switch sessionState {
        case .idle, .closed:
            return .gray
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }

    var gamePickerPlaceholder: String {
        if sessionState == .connecting {
            return "Connecting..."
        }
        if sessionState != .connected {
            return "Connect first"
        }
        if games.isEmpty {
            return "Waiting for broadcasts"
        }
        return "Select"
    }

    var placeholderCopy: BoyScreenCopy {
        if sessionState == .connecting {
            return BoyScreenCopy(
                title: "Booting link cable",
                subtitle: "Waiting for the relay session to finish connecting."
            )
        }
        if sessionState != .connected {
            return BoyScreenCopy(
                title: "Press Connect",
                subtitle:
                    "The console stays on screen, but the relay session only starts when you tap Connect."
            )
        }
        return BoyScreenCopy(
            title: "Choose a game",
            subtitle: "Broadcasts announced under boy/game will appear in the dropdown."
        )
    }

    func connect() {
        guard canConnect else { return }

        stop()
        lastError = nil

        let session = MoQSession(url: Self.relayURL)
        self.session = session

        stateObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in session.state {
                self.sessionState = state
            }
        }

        broadcastObserverTask = Task { [weak self] in
            guard let self else { return }
            for await event in session.broadcasts {
                switch event {
                case .available(let info):
                    await self.handleAvailableBroadcast(info)
                case .unavailable(let path):
                    await self.handleUnavailableBroadcast(path)
                }
            }
        }

        Task { [weak self] in
            do {
                try await session.connect()
                try session.subscribe(prefix: Self.subscribePrefix)
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.sessionState = .error(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        broadcastObserverTask?.cancel()
        broadcastObserverTask = nil
        repeatTask?.cancel()
        repeatTask = nil
        lastError = nil
        heldButtons.removeAll()
        holdStartTimes.removeAll()

        let entry = currentEntry
        currentEntry = nil

        let session = session
        let viewerPath = viewerPath
        let publisher = commandPublisher

        self.session = nil
        self.viewerPath = nil
        self.commandPublisher = nil
        self.commandEmitter = nil
        self.viewerId = nil
        self.announcedGames.removeAll()
        self.games = []
        self.selectedGamePath = nil
        self.sessionState = .idle

        Task {
            if let viewerPath, let session {
                session.unpublish(path: viewerPath)
            } else {
                publisher?.stop()
            }
            await entry?.stop()
            await session?.close()
        }
    }

    func selectGame(path: String?) {
        guard selectedGamePath != path else { return }
        selectedGamePath = path
        heldButtons.removeAll()
        holdStartTimes.removeAll()
        repeatTask?.cancel()
        repeatTask = nil
        lastError = nil
    }

    func openConsole() {
        lastError = nil

        Task { [weak self] in
            await self?.startSelectedGame()
        }
    }

    func closeConsole() {
        Task { [weak self] in
            await self?.stopCurrentPlayback()
        }
    }

    func setButton(_ button: BoyControl, isPressed: Bool) {
        guard controlsEnabled else { return }

        let commandButton = button.commandButton
        let changed: Bool
        if isPressed {
            changed = heldButtons.insert(commandButton).inserted
            if changed {
                holdStartTimes[commandButton] = DispatchTime.now().uptimeNanoseconds
            }
        } else {
            changed = heldButtons.remove(commandButton) != nil
            holdStartTimes.removeValue(forKey: commandButton)
        }

        guard changed else { return }
        sendHeldButtons()
        updateRepeatLoop()
    }

    private func handleAvailableBroadcast(_ info: MoQBroadcastInfo) async {
        guard let game = Self.makeGame(from: info) else { return }

        announcedGames[game.broadcastPath] = info
        rebuildGameList()

        if selectedGamePath == game.broadcastPath {
            await replaceCurrentBroadcast(with: info)
        }
    }

    private func handleUnavailableBroadcast(_ path: String) async {
        guard announcedGames.removeValue(forKey: path) != nil else { return }
        rebuildGameList()

        guard selectedGamePath == path else { return }
        selectedGamePath = nil
        await stopCurrentPlayback()
    }

    private func rebuildGameList() {
        games = announcedGames.values.compactMap(Self.makeGame(from:)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func startSelectedGame() async {
        await stopCurrentPlayback()

        guard let selectedGamePath, let info = announcedGames[selectedGamePath] else { return }

        await replaceCurrentBroadcast(with: info)
        if let game = Self.makeGame(from: info) {
            await startCommandPublishing(for: game)
        }
    }

    private func replaceCurrentBroadcast(with info: MoQBroadcastInfo) async {
        let previousEntry = currentEntry
        currentEntry = nil
        await previousEntry?.stop()

        let selectedTracks = preferredTracks(for: info)
        guard !selectedTracks.tracks.isEmpty else { return }

        let entry = BroadcastEntry(
            info: info,
            initialVideoTrack: selectedTracks.videoTrack,
            initialLatencyMs: 120
        )
        currentEntry = entry

        do {
            let player = try MoQPlayer(
                tracks: selectedTracks.tracks,
                targetBufferingMs: 120
            )
            entry.attach(player: player)
            try await player.play()
        } catch {
            entry.offline = true
            lastError =
                "Unable to play \(Self.displayName(for: info.path)): \(error.localizedDescription)"
        }
    }

    private func stopCurrentPlayback() async {
        heldButtons.removeAll()
        holdStartTimes.removeAll()
        repeatTask?.cancel()
        repeatTask = nil

        if let viewerPath, let session {
            session.unpublish(path: viewerPath)
        } else {
            commandPublisher?.stop()
        }

        viewerPath = nil
        viewerId = nil
        commandPublisher = nil
        commandEmitter = nil

        let entry = currentEntry
        currentEntry = nil
        await entry?.stop()
    }

    private func startCommandPublishing(for game: BoyGame) async {
        guard let session else { return }

        let emitter = MoQObjectEmitter()
        do {
            let publisher = try MoQPublisher()
            publisher.addObjectTrack(name: "command", source: emitter)

            let viewerId = Self.makeViewerId()
            let viewerPath = "\(Self.viewerPrefix)/\(game.viewerPathComponent)/\(viewerId)"

            try session.publish(path: viewerPath, publisher: publisher)
            try await publisher.start()

            self.commandEmitter = emitter
            self.commandPublisher = publisher
            self.viewerPath = viewerPath
            self.viewerId = viewerId
            sendHeldButtons()
            updateRepeatLoop()
        } catch {
            lastError = "Unable to publish controls for \(game.name): \(error.localizedDescription)"
        }
    }

    private func sendHeldButtons() {
        guard let emitter = commandEmitter else { return }

        do {
            let payload = try JSONEncoder().encode(
                BoyCommand.buttons(
                    BoyButtonsCommand(
                        buttons: heldButtons.sorted { $0.rawValue < $1.rawValue },
                        timestamps: []
                    )
                )
            )
            if let json = String(data: payload, encoding: .utf8) {
                print("Boy command payload:", json)
            }
            try emitter.send(payload)
        } catch {
            lastError = "Unable to send controller event: \(error.localizedDescription)"
        }
    }

    private func updateRepeatLoop() {
        guard commandEmitter != nil, !heldButtons.isEmpty else {
            repeatTask?.cancel()
            repeatTask = nil
            return
        }

        guard repeatTask == nil else { return }

        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.repeatIntervalNs)
                guard let self else { return }
                self.repeatHeldButtonsIfNeeded()
            }
        }
    }

    private func repeatHeldButtonsIfNeeded() {
        guard commandEmitter != nil, !heldButtons.isEmpty else {
            repeatTask?.cancel()
            repeatTask = nil
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let shouldRepeat = holdStartTimes.contains { _, startedAt in
            now >= startedAt + Self.longPressThresholdNs
        }

        guard shouldRepeat else { return }
        sendHeldButtons()
    }

    private func preferredTracks(
        for info: MoQBroadcastInfo
    ) -> (videoTrack: MoQVideoTrackInfo?, tracks: [any MoQTrackInfo]) {
        let audioTrack = info.audioTracks.first
        let highestVideoTrack = info.videoTracks.max(by: isLowerQualityVideoTrack)

        var tracks: [any MoQTrackInfo] = []
        if let highestVideoTrack {
            tracks.append(highestVideoTrack)
        }
        if let audioTrack {
            tracks.append(audioTrack)
        }

        return (highestVideoTrack, tracks)
    }

    private func isLowerQualityVideoTrack(
        _ lhs: MoQVideoTrackInfo,
        _ rhs: MoQVideoTrackInfo
    ) -> Bool {
        codedPixelCount(for: lhs) < codedPixelCount(for: rhs)
    }

    private func codedPixelCount(for track: MoQVideoTrackInfo) -> UInt64 {
        guard let coded = track.config.coded else { return 0 }
        return UInt64(coded.width) * UInt64(coded.height)
    }

    private static func makeGame(from info: MoQBroadcastInfo) -> BoyGame? {
        let component = pathComponent(from: info.path)
        return BoyGame(
            name: component,
            broadcastPath: info.path,
            viewerPathComponent: component
        )
    }

    private static func displayName(for path: String) -> String {
        pathComponent(from: path)
    }

    private static func pathComponent(from path: String) -> String {
        path
            .split(separator: "/")
            .last
            .map(String.init) ?? path
    }

    private static func makeViewerId() -> String {
        String(UUID().uuidString.lowercased().prefix(8))
    }
}
