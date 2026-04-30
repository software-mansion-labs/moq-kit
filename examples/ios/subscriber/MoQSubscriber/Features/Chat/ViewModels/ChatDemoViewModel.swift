import Foundation
import MoQKit
import SwiftUI

@MainActor
final class ChatDemoViewModel: ObservableObject {
    @Published var sessionState: SessionState = .idle
    @Published var messages: [ChatMessage] = []
    @Published var activeBroadcastCount = 0
    @Published var statusMessage = "Not connected"

    private var session: Session?
    private var subscription: BroadcastSubscription?
    private var publisher: Publisher?
    private var emitter: DataTrackEmitter?
    private var subscribePrefix = ""
    private var publishPath = ""
    private var announcedSelfPath = ""
    private var connectionToken = UUID()

    private var stateObserverTask: Task<Void, Never>?
    private var broadcastObserverTask: Task<Void, Never>?
    private var trackObserverTasks: [String: Task<Void, Never>] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    var canSend: Bool {
        sessionState == .connected && emitter != nil
    }

    var stateLabel: String {
        switch sessionState {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting..."
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
            return .blue
        case .error:
            return .red
        }
    }

    func connect(url: String, subscribePrefix: String, publishPath: String) {
        stop()

        let relayURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = subscribePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = publishPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = UUID()

        guard !relayURL.isEmpty else {
            sessionState = .error("Relay URL is required")
            statusMessage = "Relay URL is required."
            return
        }
        guard !prefix.isEmpty else {
            sessionState = .error("Subscribe prefix is required")
            statusMessage = "Subscribe prefix is required."
            return
        }
        guard !path.isEmpty else {
            sessionState = .error("Publish path is required")
            statusMessage = "Publish path is required."
            return
        }

        messages = []
        activeBroadcastCount = 0
        statusMessage = "Connecting..."
        connectionToken = token
        self.subscribePrefix = prefix
        self.publishPath = path
        announcedSelfPath = announcedPath(forPublishPath: path, subscribePrefix: prefix)
        cancelSelfTrackObservers(for: path)

        let session = Session(url: relayURL)
        self.session = session

        stateObserverTask = Task { [weak self] in
            guard let self else { return }
            for await state in session.state {
                guard self.connectionToken == token else { break }
                self.sessionState = state
            }
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                try await session.connect()
                guard self.connectionToken == token else {
                    await session.close()
                    return
                }

                let subscription = try await session.subscribe(prefix: prefix)
                guard self.connectionToken == token else {
                    subscription.cancel()
                    await session.close()
                    return
                }
                self.subscription = subscription

                let emitter = DataTrackEmitter()
                let publisher = try Publisher()
                publisher.addDataTrack(name: "chat", source: emitter)
                try await session.publish(path: path, publisher: publisher)
                try await publisher.start()
                guard self.connectionToken == token else {
                    subscription.cancel()
                    await session.unpublish(path: path)
                    await session.close()
                    return
                }

                self.emitter = emitter
                self.publisher = publisher
                self.statusMessage = "Listening under \(prefix), publishing \(path)"

                self.observeBroadcasts(subscription: subscription, publishPath: path, token: token)
            } catch {
                guard self.connectionToken == token else {
                    await session.close()
                    return
                }
                self.sessionState = .error(error.localizedDescription)
                self.statusMessage = error.localizedDescription
                await session.close()
            }
        }
    }

    func send(text: String, displayName: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return false }
        guard !name.isEmpty else {
            statusMessage = "Display name is required."
            return false
        }
        guard let emitter else {
            statusMessage = "Connect before sending messages."
            return false
        }

        do {
            let payload = ChatPayload(from: name, message: body)
            let data = try encoder.encode(payload)
            try emitter.send(data)
            appendMessage(payload, direction: .local, broadcastPath: publishPath)
            return true
        } catch {
            statusMessage = "Send failed: \(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        connectionToken = UUID()

        stateObserverTask?.cancel()
        stateObserverTask = nil

        broadcastObserverTask?.cancel()
        broadcastObserverTask = nil

        for task in trackObserverTasks.values {
            task.cancel()
        }
        trackObserverTasks.removeAll()
        activeBroadcastCount = 0

        let subscription = subscription
        self.subscription = nil
        subscription?.cancel()

        let session = session
        let path = publishPath
        self.session = nil
        publisher = nil
        emitter = nil
        subscribePrefix = ""
        publishPath = ""
        announcedSelfPath = ""

        if sessionState != .idle {
            sessionState = .idle
        }
        statusMessage = "Not connected"

        Task {
            if !path.isEmpty {
                await session?.unpublish(path: path)
            }
            await session?.close()
        }
    }

    private func observeBroadcasts(
        subscription: BroadcastSubscription,
        publishPath: String,
        token: UUID
    ) {
        broadcastObserverTask?.cancel()
        broadcastObserverTask = Task { [weak self] in
            guard let self else { return }

            for await broadcast in subscription.broadcasts {
                guard self.connectionToken == token else { break }
                guard !self.isSelfBroadcastPath(broadcast.path, publishPath: publishPath) else {
                    self.cancelSelfTrackObservers(for: broadcast.path)
                    continue
                }
                self.observeChatTrack(for: broadcast, token: token)
            }
        }
    }

    private func observeChatTrack(for broadcast: Broadcast, token: UUID) {
        guard connectionToken == token else { return }
        guard !isSelfBroadcastPath(broadcast.path) else {
            cancelSelfTrackObservers(for: broadcast.path)
            return
        }

        trackObserverTasks[broadcast.path]?.cancel()

        let path = broadcast.path
        trackObserverTasks[path] = Task { [weak self] in
            guard let self else { return }

            do {
                guard self.connectionToken == token else { return }
                let subscription = try broadcast.subscribeTrack(name: "chat", delivery: .arrival)
                defer { subscription.close() }
                guard self.connectionToken == token, !self.isSelfBroadcastPath(path) else {
                    return
                }

                self.activeBroadcastCount = self.trackObserverTasks.count

                for try await object in subscription.objects {
                    guard self.connectionToken == token, !self.isSelfBroadcastPath(path) else {
                        break
                    }
                    guard let payload = try? self.decoder.decode(
                        ChatPayload.self,
                        from: object.payload
                    ) else {
                        self.statusMessage = "Ignored invalid chat payload from \(path)"
                        continue
                    }
                    self.appendMessage(payload, direction: .remote, broadcastPath: path)
                }
            } catch is CancellationError {
            } catch {
                self.statusMessage = "Chat track ended for \(path): \(error.localizedDescription)"
            }

            self.trackObserverTasks.removeValue(forKey: path)
            self.activeBroadcastCount = self.trackObserverTasks.count
        }
    }

    private func appendMessage(
        _ payload: ChatPayload,
        direction: ChatMessage.Direction,
        broadcastPath: String
    ) {
        messages.append(
            ChatMessage(
                direction: direction,
                from: payload.from,
                text: payload.message,
                broadcastPath: broadcastPath,
                timestamp: Date()
            )
        )
    }

    private func isSelfBroadcastPath(_ broadcastPath: String, publishPath: String? = nil) -> Bool {
        let path = publishPath ?? self.publishPath
        let normalizedPublishPath = normalizedBroadcastPath(path)
        let normalizedAnnouncedSelfPath: String
        if path == self.publishPath {
            normalizedAnnouncedSelfPath = normalizedBroadcastPath(announcedSelfPath)
        } else {
            normalizedAnnouncedSelfPath = normalizedBroadcastPath(
                announcedPath(forPublishPath: path, subscribePrefix: subscribePrefix)
            )
        }
        let normalizedBroadcastPath = normalizedBroadcastPath(broadcastPath)

        guard !normalizedBroadcastPath.isEmpty else { return false }
        return normalizedBroadcastPath == normalizedPublishPath
            || normalizedBroadcastPath == normalizedAnnouncedSelfPath
    }

    private func cancelSelfTrackObservers(for path: String) {
        let selfTrackPaths = trackObserverTasks.keys.filter {
            isSelfBroadcastPath($0, publishPath: path)
        }

        for trackedPath in selfTrackPaths {
            trackObserverTasks[trackedPath]?.cancel()
            trackObserverTasks.removeValue(forKey: trackedPath)
        }
        activeBroadcastCount = trackObserverTasks.count
    }

    private func normalizedBroadcastPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func announcedPath(forPublishPath publishPath: String, subscribePrefix: String) -> String {
        let normalizedPublishPath = normalizedBroadcastPath(publishPath)
        let normalizedSubscribePrefix = normalizedBroadcastPath(subscribePrefix)

        guard !normalizedPublishPath.isEmpty, !normalizedSubscribePrefix.isEmpty else {
            return normalizedPublishPath
        }
        guard normalizedPublishPath != normalizedSubscribePrefix else { return "" }

        let prefixWithSeparator = normalizedSubscribePrefix + "/"
        if normalizedPublishPath.hasPrefix(prefixWithSeparator) {
            return String(normalizedPublishPath.dropFirst(prefixWithSeparator.count))
        }
        return normalizedPublishPath
    }
}
