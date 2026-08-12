import Combine
import MoQKit
import os

@MainActor
final class DVRPlaybackController: ObservableObject {
    @Published private(set) var player: DVR.Player?
    @Published private(set) var isAvailable = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPresented = false
    @Published private(set) var error: String?

    private let broadcastPath: String
    private var timelineResolver: DVR.TimelineResolver?
    private var isIndexingEnabled = false
    private var lifecycleGeneration = 0

    init(broadcastPath: String) {
        self.broadcastPath = broadcastPath
    }

    func startIndexing(
        catalog: Catalog,
        videoTrackName: String?,
        audioTrackName: String?
    ) async {
        isIndexingEnabled = true

        guard timelineResolver == nil else {
            broadcastEntryLogger.debug(
                "DVR indexing already active path=\(self.broadcastPath, privacy: .public)"
            )
            return
        }

        let generation = invalidateLifecycle()
        isLoading = false
        await replaceTimelineResolver(
            previousResolver: nil,
            catalog: catalog,
            videoTrackName: videoTrackName,
            audioTrackName: audioTrackName,
            generation: generation
        )
    }

    func reindex(
        catalog: Catalog,
        videoTrackName: String?,
        audioTrackName: String?
    ) {
        guard isIndexingEnabled else { return }

        let generation = invalidateLifecycle()
        let previousResolver = timelineResolver
        timelineResolver = nil
        isAvailable = false
        isLoading = false

        Task { [weak self] in
            await self?.replaceTimelineResolver(
                previousResolver: previousResolver,
                catalog: catalog,
                videoTrackName: videoTrackName,
                audioTrackName: audioTrackName,
                generation: generation
            )
        }
    }

    func rewindLast15Seconds(
        catalog: Catalog,
        videoTrackName: String?,
        audioTrackName: String?,
        volume: Float
    ) async {
        guard let timelineResolver else {
            broadcastEntryLogger.warning(
                "DVR rewind ignored because timeline resolver is unavailable path=\(self.broadcastPath, privacy: .public)"
            )
            return
        }
        guard let videoTrackName, let audioTrackName else {
            broadcastEntryLogger.warning(
                "DVR rewind ignored because selected tracks are missing path=\(self.broadcastPath, privacy: .public) video=\(videoTrackName ?? "none", privacy: .public) audio=\(audioTrackName ?? "none", privacy: .public)"
            )
            return
        }

        broadcastEntryLogger.debug(
            "DVR rewind requested path=\(self.broadcastPath, privacy: .public) durationSeconds=15"
        )
        let generation = invalidateLifecycle()
        isLoading = true
        error = nil

        do {
            let selection = try await timelineResolver.selection(for: .seconds(15))
            guard lifecycleGeneration == generation else { return }
            guard
                selection.video.name == videoTrackName,
                selection.audio.name == audioTrackName
            else {
                throw SessionError.invalidConfiguration(
                    "The selected tracks changed while preparing DVR playback"
                )
            }

            broadcastEntryLogger.debug(
                "DVR rewind selection path=\(self.broadcastPath, privacy: .public) video=\(selection.video.name, privacy: .public) videoBoundaries=\(selection.video.timeline.count) audio=\(selection.audio.name, privacy: .public) audioBoundaries=\(selection.audio.timeline.count)"
            )
            let newPlayer = try await DVR.Player(catalog: catalog, selection: selection)
            guard lifecycleGeneration == generation else {
                newPlayer.stop()
                return
            }

            player?.stop()
            player = newPlayer
            isPresented = true
            isLoading = false
            newPlayer.player.volume = volume
            newPlayer.player.play()
            broadcastEntryLogger.debug(
                "DVR rewind playback requested path=\(self.broadcastPath, privacy: .public) volume=\(newPlayer.player.volume) itemStatus=\(newPlayer.item.status.rawValue)"
            )
        } catch {
            guard lifecycleGeneration == generation else { return }
            self.error = error.localizedDescription
            isLoading = false
            broadcastEntryLogger.error(
                "DVR rewind failed path=\(self.broadcastPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func dismiss() {
        broadcastEntryLogger.debug(
            "DVR presentation dismissed path=\(self.broadcastPath, privacy: .public)"
        )
        _ = invalidateLifecycle()
        player?.stop()
        player = nil
        isPresented = false
        isLoading = false
    }

    func setPresented(_ isPresented: Bool) {
        self.isPresented = isPresented
    }

    func stop() async {
        isIndexingEnabled = false
        _ = invalidateLifecycle()

        let resolver = timelineResolver
        timelineResolver = nil
        let currentPlayer = player
        player = nil
        isAvailable = false
        isLoading = false
        isPresented = false
        error = nil

        currentPlayer?.stop()
        await resolver?.stop()
    }

    private func replaceTimelineResolver(
        previousResolver: DVR.TimelineResolver?,
        catalog: Catalog,
        videoTrackName: String?,
        audioTrackName: String?,
        generation: Int
    ) async {
        await previousResolver?.stop()
        guard lifecycleGeneration == generation, isIndexingEnabled else { return }

        guard let videoTrackName, let audioTrackName else {
            broadcastEntryLogger.warning(
                "DVR indexing skipped because selected tracks are missing path=\(self.broadcastPath, privacy: .public) video=\(videoTrackName ?? "none", privacy: .public) audio=\(audioTrackName ?? "none", privacy: .public)"
            )
            return
        }

        broadcastEntryLogger.debug(
            "DVR indexing starting path=\(self.broadcastPath, privacy: .public) video=\(videoTrackName, privacy: .public) audio=\(audioTrackName, privacy: .public)"
        )

        var resolver: DVR.TimelineResolver?
        do {
            let newResolver = try DVR.TimelineResolver(
                catalog: catalog,
                videoTrackName: videoTrackName,
                audioTrackName: audioTrackName
            )
            resolver = newResolver
            timelineResolver = newResolver
            try await newResolver.start()
            guard lifecycleGeneration == generation, isIndexingEnabled else {
                await newResolver.stop()
                if timelineResolver === newResolver {
                    timelineResolver = nil
                }
                return
            }

            isAvailable = true
            error = nil
            broadcastEntryLogger.debug(
                "DVR indexing started path=\(self.broadcastPath, privacy: .public)"
            )
        } catch {
            if let resolver {
                await resolver.stop()
                if timelineResolver === resolver {
                    timelineResolver = nil
                }
            }
            guard lifecycleGeneration == generation, isIndexingEnabled else { return }

            isAvailable = false
            self.error = error.localizedDescription
            broadcastEntryLogger.warning(
                "DVR indexing unavailable path=\(self.broadcastPath, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func invalidateLifecycle() -> Int {
        lifecycleGeneration += 1
        return lifecycleGeneration
    }
}
