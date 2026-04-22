import Foundation
import MoQKitFFI

// MARK: - VideoSize

/// A pair of pixel dimensions used to describe video resolution or display ratio.
public struct VideoSize: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
}

// MARK: - VideoTrackConfig

/// Codec and format parameters for a video rendition.
public struct VideoTrackConfig: Sendable {
    /// Codec identifier string (e.g. `"avc1"`, `"hev1"`, `"av01"`).
    public let codec: String
    /// Coded frame dimensions in pixels. `nil` when not specified by the publisher.
    public let coded: VideoSize?
    /// Display aspect ratio. `nil` when not specified by the publisher.
    public let displayRatio: VideoSize?
    /// Target bitrate in bits per second. `nil` when not specified.
    public let bitrate: UInt64?
    /// Frame rate in frames per second. `nil` when not specified.
    public let framerate: Double?

    init(_ raw: MoqVideo) {
        self.codec = raw.codec
        self.coded = raw.coded.map { VideoSize(width: $0.width, height: $0.height) }
        self.displayRatio = raw.displayRatio.map { VideoSize(width: $0.width, height: $0.height) }
        self.bitrate = raw.bitrate
        self.framerate = raw.framerate
    }
}

extension VideoTrackConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), width=\(coded?.width ?? 0), height=\(coded?.height ?? 0)"
    }
}

// MARK: - AudioTrackConfig

/// Codec and format parameters for an audio rendition.
public struct AudioTrackConfig: Sendable {
    /// Codec identifier string (e.g. `"mp4a.40.2"` for AAC, `"opus"` for Opus).
    public let codec: String
    /// Sample rate in Hz (e.g. `44100`, `48000`).
    public let sampleRate: UInt32
    /// Number of audio channels (e.g. `1` for mono, `2` for stereo).
    public let channelCount: UInt32
    /// Target bitrate in bits per second. `nil` when not specified.
    public let bitrate: UInt64?

    init(_ raw: MoqAudio) {
        self.codec = raw.codec
        self.sampleRate = raw.sampleRate
        self.channelCount = raw.channelCount
        self.bitrate = raw.bitrate
    }
}

extension AudioTrackConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "codec=\(codec), sampleRate=\(sampleRate), channels=\(channelCount)"
    }
}

// MARK: - Track Info Types

/// A type that describes a single media track within a broadcast.
///
/// Concrete types are ``VideoTrackInfo`` and ``AudioTrackInfo``.
public protocol TrackInfo: Sendable {
    /// The track name used to subscribe on the relay.
    var name: String { get }
}

/// Describes a video track within a broadcast, including its codec and resolution.
public struct VideoTrackInfo: TrackInfo, Sendable {
    /// The track name used to subscribe on the relay.
    public let name: String
    /// Codec, resolution, and format parameters for this video rendition.
    public let config: VideoTrackConfig

    let rawConfig: MoqVideo

    init(name: String, config: MoqVideo) {
        self.name = name
        self.rawConfig = config
        self.config = VideoTrackConfig(config)
    }
}

/// Describes an audio track within a broadcast, including its codec and sample rate.
public struct AudioTrackInfo: TrackInfo, Sendable {
    /// The track name used to subscribe on the relay.
    public let name: String
    /// Codec, sample rate, and channel configuration for this audio rendition.
    public let config: AudioTrackConfig

    let rawConfig: MoqAudio

    init(name: String, config: MoqAudio) {
        self.name = name
        self.rawConfig = config
        self.config = AudioTrackConfig(config)
    }
}

/// Describes the tracks available in a live broadcast at a given relay path.
///
/// Each `Catalog` update represents the latest playable track metadata for a broadcast.
/// Pass a catalog into ``Player/init(catalog:videoTrackName:audioTrackName:targetBufferingMs:)``
/// to begin playback.
public struct Catalog: Sendable {
    /// The relay path that identifies this broadcast (e.g. `"live/game1"`).
    public let path: String
    /// Available video renditions. Typically one entry per resolution/bitrate tier.
    public let videoTracks: [VideoTrackInfo]
    /// Available audio renditions. Typically one or more language/codec variants.
    public let audioTracks: [AudioTrackInfo]

    let broadcast: MoqBroadcastConsumer

    init(path: String, catalog: MoqCatalog, broadcast: MoqBroadcastConsumer) {
        self.path = path
        self.broadcast = broadcast
        self.videoTracks = catalog.video.map { name, rendition in
            VideoTrackInfo(name: name, config: rendition)
        }
        self.audioTracks = catalog.audio.map { name, rendition in
            AudioTrackInfo(name: name, config: rendition)
        }
    }
}

/// A live broadcast announcement surfaced by a ``BroadcastSubscription``.
public struct Broadcast: Sendable {
    /// The relay path that identifies this broadcast (e.g. `"live/game1"`).
    public let path: String

    let consumer: MoqBroadcastConsumer

    init(path: String, consumer: MoqBroadcastConsumer) {
        self.path = path
        self.consumer = consumer
    }

    /// Streams catalog updates for this broadcast until the catalog track ends.
    public func catalogs() -> AsyncStream<Catalog> {
        AsyncStream { continuation in
            let catalogConsumer: MoqCatalogConsumer
            do {
                catalogConsumer = try consumer.subscribeCatalog()
            } catch {
                KitLogger.session.error("Failed to subscribe to catalog for \(self.path): \(error)")
                continuation.finish()
                return
            }

            let task = Task.detached {
                defer { continuation.finish() }

                while !Task.isCancelled {
                    do {
                        guard let catalog = try await catalogConsumer.next() else {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        continuation.yield(Catalog(path: self.path, catalog: catalog, broadcast: self.consumer))
                    } catch MoqError.Cancelled {
                        return
                    } catch {
                        KitLogger.session.error("Catalog stream failed for \(self.path): \(error)")
                        return
                    }
                }
            }

            continuation.onTermination = { _ in
                catalogConsumer.cancel()
                task.cancel()
            }
        }
    }
}

/// A prefix-based subscription created by ``Session/subscribe(prefix:)``.
public final class BroadcastSubscription: @unchecked Sendable {
    /// The prefix used when subscribing to relay announcements.
    public let prefix: String
    /// Emits broadcasts announced under ``prefix``.
    public let broadcasts: AsyncStream<Broadcast>

    private let lock = UnfairLock()
    private weak var session: Session?
    private let broadcastsContinuation: AsyncStream<Broadcast>.Continuation
    private var announced: MoqAnnounced?
    private var observeTask: Task<Void, Never>?
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    init(prefix: String, session: Session, announced: MoqAnnounced) {
        self.prefix = prefix
        self.session = session
        self.announced = announced

        var continuation: AsyncStream<Broadcast>.Continuation!
        self.broadcasts = AsyncStream { continuation = $0 }
        self.broadcastsContinuation = continuation

        continuation.onTermination = { [weak self] _ in
            self?.finish(cancelAnnounced: true, unregister: true)
        }

        observeTask = Task { [weak self] in
            guard let self else { return }
            await self.observeAnnouncements()
        }
    }

    /// Cancels the subscription and allows the same prefix to be subscribed again.
    public func cancel() {
        finish(cancelAnnounced: true, unregister: true)
    }

    private func observeAnnouncements() async {
        guard let announced else {
            finish(cancelAnnounced: false, unregister: true)
            return
        }

        while !Task.isCancelled {
            do {
                guard let announcement = try await announced.next() else {
                    finish(cancelAnnounced: false, unregister: true)
                    return
                }
                guard !Task.isCancelled else { break }

                let broadcast = Broadcast(
                    path: announcement.path(),
                    consumer: announcement.broadcast()
                )
                yield(broadcast)
            } catch MoqError.Cancelled {
                break
            } catch {
                KitLogger.session.error(
                    "Announcement stream failed for prefix \(self.prefix): \(error)")
                break
            }
        }

        finish(cancelAnnounced: false, unregister: true)
    }

    private func yield(_ broadcast: Broadcast) {
        let continuation = lock.withLock { () -> AsyncStream<Broadcast>.Continuation? in
            guard !finished else { return nil }
            return broadcastsContinuation
        }
        continuation?.yield(broadcast)
    }

    private func unregisterFromSession() {
        Task { [weak session, prefix, weak self] in
            guard let self else { return }
            await session?.removeSubscription(prefix: prefix, matching: self)
        }
    }

    private func finish(cancelAnnounced: Bool, unregister: Bool) {
        let state = lock.withLock { () -> (MoqAnnounced?, Task<Void, Never>?)? in
            guard !finished else { return nil }
            finished = true

            let announced = self.announced
            self.announced = nil

            let observeTask = self.observeTask
            self.observeTask = nil

            return (announced, observeTask)
        }
        guard let state else { return }

        state.1?.cancel()
        if cancelAnnounced {
            state.0?.cancel()
        }
        broadcastsContinuation.finish()

        if unregister {
            unregisterFromSession()
        }
    }
}
