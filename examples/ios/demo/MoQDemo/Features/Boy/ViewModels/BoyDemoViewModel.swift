import MoQKit
import SwiftUI

@MainActor
final class BoyDemoViewModel: ObservableObject {
    static let relayURL = "https://cdn.moq.dev/demo"

    private static let subscribePrefix = "boy"
    private static let viewerPrefix = "viewer/boy"
    private static let repeatIntervalNs: UInt64 = 10_000_000
    private static let longPressThresholdNs: UInt64 = 300_000_000
    private static let defaultTargetLatencyMs: UInt64 = 200

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var games: [BoyGame] = []
    @Published private(set) var currentEntry: BroadcastEntry?
    @Published private(set) var selectedGamePath: String?
    @Published var targetLatencyMs: Double = Double(defaultTargetLatencyMs)
    @Published var lastError: String?

    private var session: Session?
    private var subscription: BroadcastSubscription?
    private var announcedGames: [String: Catalog] = [:]
    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?
    private var catalogObserverTasks: [String: Task<Void, Never>] = [:]
    private var commandPublisher: Publisher?
    private var commandEmitter: DataTrackEmitter?
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

    var isConnecting: Bool {
        sessionState == .connecting
    }

    var isConnected: Bool {
        sessionState == .connected
    }

    var hasAvailableGames: Bool {
        !games.isEmpty
    }

    var controlsEnabled: Bool {
        currentEntry != nil && commandEmitter != nil
    }

    var selectedGameName: String? {
        guard let selectedGamePath else { return nil }
        return games.first(where: { $0.broadcastPath == selectedGamePath })?.name
            ?? Self.displayName(for: selectedGamePath)
    }

    var placeholderCopy: BoyScreenCopy {
        if sessionState == .connecting {
            return BoyScreenCopy(
                title: "Powering on",
                subtitle: "The relay session is starting up."
            )
        }
        if sessionState != .connected {
            return BoyScreenCopy(
                title: "Power is off",
                subtitle: "Slide the switch at the top to connect this console."
            )
        }
        if let selectedGameName {
            return BoyScreenCopy(
                title: "Waiting for \(selectedGameName)",
                subtitle: "This cartridge will start as soon as its broadcast appears on the relay."
            )
        }
        return BoyScreenCopy(
            title: "Insert a cartridge",
            subtitle: "Flip the console, choose a game, then flip back to play."
        )
    }

    var latencyLabel: String {
        "\(Int(targetLatencyMs)) ms"
    }

    func connect() {
        guard canConnect else { return }

        stop()
        lastError = nil

        let session = Session(url: Self.relayURL)
        self.session = session

        stateObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in session.state {
                self.sessionState = state
            }
        }

        Task { [weak self] in
            do {
                try await session.connect()
                let subscription = try await session.subscribe(prefix: Self.subscribePrefix)
                await MainActor.run {
                    self?.subscription = subscription
                    self?.broadcastObserverTask = Task { [weak self] in
                        guard let self else { return }
                        for await broadcast in subscription.broadcasts {
                            self.observeCatalogs(for: broadcast)
                        }
                    }
                }
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
        for (_, task) in catalogObserverTasks {
            task.cancel()
        }
        catalogObserverTasks.removeAll()
        repeatTask?.cancel()
        repeatTask = nil
        lastError = nil
        heldButtons.removeAll()
        holdStartTimes.removeAll()

        let entry = currentEntry
        currentEntry = nil

        let session = session
        let subscription = subscription
        let viewerPath = viewerPath
        let publisher = commandPublisher

        self.session = nil
        self.subscription = nil
        self.viewerPath = nil
        self.commandPublisher = nil
        self.commandEmitter = nil
        self.announcedGames.removeAll()
        self.games = []
        self.selectedGamePath = nil
        self.sessionState = .idle

        Task {
            if let viewerPath, let session {
                await session.unpublish(path: viewerPath)
            } else {
                publisher?.stop()
            }
            await entry?.stop()
            subscription?.cancel()
            await session?.close()
        }
    }

    func selectGame(path: String?) {
        let changedSelection = selectedGamePath != path
        selectedGamePath = path
        heldButtons.removeAll()
        holdStartTimes.removeAll()
        repeatTask?.cancel()
        repeatTask = nil
        lastError = nil

        guard changedSelection || path == nil || currentEntry?.broadcastPath != path else { return }

        Task { [weak self] in
            guard let self else { return }
            if path == nil {
                await self.stopCurrentPlayback()
                return
            }

            guard self.sessionState == .connected else { return }
            await self.startSelectedGame()
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

    func updateTargetLatency(ms: Double) {
        let steppedLatency = min(2000, max(50, (ms / 50).rounded() * 50))
        targetLatencyMs = steppedLatency
        currentEntry?.updateTargetLatency(ms: UInt64(steppedLatency))
    }

    private func observeCatalogs(for broadcast: Broadcast) {
        catalogObserverTasks[broadcast.path]?.cancel()
        catalogObserverTasks[broadcast.path] = Task { [weak self] in
            guard let self else { return }

            for await catalog in broadcast.catalogs() {
                await self.handleAvailableBroadcast(catalog)
            }

            guard !Task.isCancelled else { return }
            await self.handleUnavailableBroadcast(broadcast.path)
            self.catalogObserverTasks.removeValue(forKey: broadcast.path)
        }
    }

    private func handleAvailableBroadcast(_ catalog: Catalog) async {
        guard let game = Self.makeGame(from: catalog) else { return }

        announcedGames[game.broadcastPath] = catalog
        rebuildGameList()

        if selectedGamePath == game.broadcastPath, sessionState == .connected {
            let needsPlaybackRefresh =
                currentEntry?.broadcastPath != game.broadcastPath
                || currentEntry?.offline == true
                || commandEmitter == nil

            if needsPlaybackRefresh {
                await startSelectedGame()
            }
        }
    }

    private func handleUnavailableBroadcast(_ path: String) async {
        guard announcedGames.removeValue(forKey: path) != nil else { return }
        rebuildGameList()

        guard selectedGamePath == path else { return }
        await stopCurrentPlayback()
    }

    private func rebuildGameList() {
        games = announcedGames.values.compactMap(Self.makeGame(from:)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func startSelectedGame() async {
        await stopCurrentPlayback()

        guard let selectedGamePath, let catalog = announcedGames[selectedGamePath] else { return }

        await replaceCurrentBroadcast(with: catalog)
        if let game = Self.makeGame(from: catalog) {
            await startCommandPublishing(for: game)
        }
    }

    private func replaceCurrentBroadcast(with catalog: Catalog) async {
        let previousEntry = currentEntry
        currentEntry = nil
        await previousEntry?.stop()

        let selectedTracks = preferredTracks(for: catalog)
        guard selectedTracks.videoTrackName != nil || selectedTracks.audioTrackName != nil else {
            return
        }

        let entry = BroadcastEntry(
            catalog: catalog,
            initialVideoTrackName: selectedTracks.videoTrackName,
            initialLatencyMs: UInt64(targetLatencyMs)
        )
        currentEntry = entry

        do {
            let player = try Player(
                catalog: catalog,
                videoTrackName: selectedTracks.videoTrackName,
                audioTrackName: selectedTracks.audioTrackName,
                targetBufferingMs: UInt64(targetLatencyMs)
            )
            entry.attach(player: player)
            try await player.play()
        } catch {
            entry.offline = true
            lastError =
                "Unable to play \(Self.displayName(for: catalog.path)): \(error.localizedDescription)"
        }
    }

    private func stopCurrentPlayback() async {
        heldButtons.removeAll()
        holdStartTimes.removeAll()
        repeatTask?.cancel()
        repeatTask = nil

        if let viewerPath, let session {
            await session.unpublish(path: viewerPath)
        } else {
            commandPublisher?.stop()
        }

        viewerPath = nil
        commandPublisher = nil
        commandEmitter = nil

        let entry = currentEntry
        currentEntry = nil
        await entry?.stop()
    }

    private func startCommandPublishing(for game: BoyGame) async {
        guard let session else { return }

        let emitter = DataTrackEmitter()
        do {
            let publisher = try Publisher()
            publisher.addDataTrack(name: "command", source: emitter)

            let viewerId = Self.makeViewerId()
            let viewerPath = "\(Self.viewerPrefix)/\(game.viewerPathComponent)/\(viewerId)"

            try await session.publish(path: viewerPath, publisher: publisher)
            try await publisher.start()

            self.commandEmitter = emitter
            self.commandPublisher = publisher
            self.viewerPath = viewerPath
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
        for catalog: Catalog
    ) -> (videoTrackName: String?, audioTrackName: String?) {
        let audioTrackName = catalog.audioTracks.first?.name
        let highestVideoTrackName = catalog.videoTracks.max(by: isLowerQualityVideoTrack)?.name
        return (highestVideoTrackName, audioTrackName)
    }

    private func isLowerQualityVideoTrack(
        _ lhs: VideoTrackInfo,
        _ rhs: VideoTrackInfo
    ) -> Bool {
        codedPixelCount(for: lhs) < codedPixelCount(for: rhs)
    }

    private func codedPixelCount(for track: VideoTrackInfo) -> UInt64 {
        guard let coded = track.config.coded else { return 0 }
        return UInt64(coded.width) * UInt64(coded.height)
    }

    private static func makeGame(from catalog: Catalog) -> BoyGame? {
        let component = pathComponent(from: catalog.path)
        return BoyGame(
            name: component,
            broadcastPath: catalog.path,
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
