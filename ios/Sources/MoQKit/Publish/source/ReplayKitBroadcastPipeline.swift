import CoreMedia
import Foundation
import ReplayKit
import UIKit

/// Minimal connection details shared between the host app and ReplayKit extension.
public struct ReplayKitBroadcastDescriptor: Codable, Sendable {
    /// Relay URL the extension should connect to.
    public var relayURL: String
    /// Broadcast path the extension should publish to.
    public var broadcastPath: String

    /// Creates a minimal descriptor that the host app can share with the extension.
    public init(relayURL: String, broadcastPath: String) {
        self.relayURL = relayURL
        self.broadcastPath = broadcastPath
    }
}

/// Errors emitted by ReplayKit helpers.
public enum ReplayKitBroadcastError: Error, Sendable {
    /// The configured App Group is missing or not accessible to the current target.
    case invalidAppGroup(String)
    /// No stored descriptor was found in the shared App Group store.
    case missingDescriptor
    /// Required descriptor fields were missing or malformed.
    case invalidDescriptor(String)
    /// Neither setup info nor App Group fallback produced a usable configuration.
    case missingConfiguration
    /// ReplayKit setup info could not be decoded into a broadcast configuration.
    case invalidSetupInfo(String)
    /// The broadcast pipeline was already started.
    case alreadyStarted
}

/// Persists ReplayKit publish configuration in an App Group for host app ↔ extension sharing.
public struct ReplayKitBroadcastDescriptorStore: Sendable {
    /// Default `UserDefaults` key used by MoQKit demos and helpers.
    public static let defaultKey = "moqkit.replaykit.broadcastDescriptor"

    /// Shared App Group identifier used to open the shared container.
    public let appGroupIdentifier: String
    /// `UserDefaults` key used to store the descriptor payload.
    public let key: String

    /// Creates a descriptor store backed by an App Group `UserDefaults` suite.
    public init(
        appGroupIdentifier: String,
        key: String = defaultKey
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.key = key
    }

    private func sharedDefaults() throws -> UserDefaults {
        // Validate entitlement/container first so callers get a deterministic error
        // instead of CFPreferences warnings when the App Group is not configured.
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil else {
            throw ReplayKitBroadcastError.invalidAppGroup(
                "\(appGroupIdentifier) is not available to this target (missing App Group capability or provisioning)."
            )
        }

        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            throw ReplayKitBroadcastError.invalidAppGroup(appGroupIdentifier)
        }
        return defaults
    }

    /// Stores the latest descriptor for later extension startup.
    public func save(_ descriptor: ReplayKitBroadcastDescriptor) throws {
        let defaults = try sharedDefaults()
        let encoded = try JSONEncoder().encode(descriptor)
        defaults.set(encoded, forKey: key)
    }

    /// Loads the most recently stored descriptor.
    public func load() throws -> ReplayKitBroadcastDescriptor {
        let defaults = try sharedDefaults()
        guard let encoded = defaults.data(forKey: key) else {
            throw ReplayKitBroadcastError.missingDescriptor
        }
        do {
            return try JSONDecoder().decode(ReplayKitBroadcastDescriptor.self, from: encoded)
        } catch {
            throw ReplayKitBroadcastError.invalidDescriptor(error.localizedDescription)
        }
    }

    /// Removes any stored descriptor from the shared container.
    public func clear() throws {
        let defaults = try sharedDefaults()
        defaults.removeObject(forKey: key)
    }
}

/// Full ReplayKit publishing configuration for a Broadcast Upload extension.
public struct ReplayKitBroadcastConfiguration: Sendable, Codable {
    /// Relay location and broadcast path to publish.
    public var descriptor: ReplayKitBroadcastDescriptor
    /// Name of the screen-video track.
    public var videoTrackName: String
    /// Optional app-audio track name. Set to `nil` to skip app audio publishing.
    public var appAudioTrackName: String?
    /// Optional microphone track name. Set to `nil` to skip microphone publishing.
    public var micAudioTrackName: String?
    /// Encoder settings for screen video.
    public var videoEncoder: VideoEncoderConfig
    /// Encoder settings for app audio.
    public var appAudioEncoder: AudioEncoderConfig
    /// Encoder settings for microphone audio.
    public var micAudioEncoder: AudioEncoderConfig

    /// Creates a ReplayKit publish configuration.
    public init(
        descriptor: ReplayKitBroadcastDescriptor,
        videoTrackName: String = "screen",
        appAudioTrackName: String? = "screen-audio",
        micAudioTrackName: String? = nil,
        videoEncoder: VideoEncoderConfig = VideoEncoderConfig(),
        appAudioEncoder: AudioEncoderConfig = AudioEncoderConfig(),
        micAudioEncoder: AudioEncoderConfig = AudioEncoderConfig()
    ) {
        self.descriptor = descriptor
        self.videoTrackName = videoTrackName
        self.appAudioTrackName = appAudioTrackName
        self.micAudioTrackName = micAudioTrackName
        self.videoEncoder = videoEncoder
        self.appAudioEncoder = appAudioEncoder
        self.micAudioEncoder = micAudioEncoder
    }
}

/// Helpers for encoding ReplayKit setup info used to bootstrap extension publishing.
public enum ReplayKitBroadcastSetupInfo {
    /// Key used when setup info carries a nested configuration payload.
    public static let configurationKey = "moqkit.replaykit.config"

    /// Encodes a configuration for `RPBroadcastActivityViewController` setup info.
    public static func makeSetupInfo(
        configuration: ReplayKitBroadcastConfiguration,
        key: String = configurationKey
    ) throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(configuration)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            JSONSerialization.isValidJSONObject(json)
        else {
            throw ReplayKitBroadcastError.invalidSetupInfo("Failed to encode setup info JSON")
        }

        var output: [String: NSObject] = [:]
        output[key] = json as NSDictionary
        return output
    }
}

/// MoQ publishing pipeline for use inside a ReplayKit Broadcast Upload Extension.
///
/// Use this from `RPBroadcastSampleHandler` to publish full-device screen capture while
/// the host app is backgrounded. Most apps can subclass
/// ``MoQReplayKitBroadcastSampleHandler`` instead of instantiating this actor directly.
public actor ReplayKitBroadcastPipeline {
    private let configuration: ReplayKitBroadcastConfiguration
    private let videoSource = FrameRelay()
    private let appAudioSource = FrameRelay()
    private let micAudioSource = FrameRelay()

    private var session: Session?
    private var publisher: Publisher?
    private var isRunning = false

    /// Creates a pipeline for one ReplayKit extension publishing session.
    public init(configuration: ReplayKitBroadcastConfiguration) {
        self.configuration = configuration
    }

    private func resolvedScreenVideoEncoderConfig() async -> VideoEncoderConfig {
        var resolved = configuration.videoEncoder

        let screenMetrics = await MainActor.run { () -> (width: Int32, height: Int32, maxFps: Double)? in
            let screen = UIScreen.main
            let nativeBounds = screen.nativeBounds
            let width = Int32(max(1, Int(nativeBounds.width.rounded())))
            let height = Int32(max(1, Int(nativeBounds.height.rounded())))
            let maxFps = Double(max(1, screen.maximumFramesPerSecond))
            return (width: width, height: height, maxFps: maxFps)
        }

        if let screenMetrics {
            resolved.width = screenMetrics.width
            resolved.height = screenMetrics.height
            resolved.maxFrameRate = screenMetrics.maxFps
        }

        return resolved
    }

    /// Connects to the relay, registers the publisher, and starts forwarding ReplayKit samples.
    ///
    /// Call this from your extension startup path, typically `broadcastStarted`.
    public func start() async throws {
        guard !isRunning else {
            throw ReplayKitBroadcastError.alreadyStarted
        }
        guard !configuration.descriptor.relayURL.isEmpty else {
            throw ReplayKitBroadcastError.invalidDescriptor("relayURL must not be empty")
        }
        guard !configuration.descriptor.broadcastPath.isEmpty else {
            throw ReplayKitBroadcastError.invalidDescriptor("broadcastPath must not be empty")
        }
        guard !configuration.videoTrackName.isEmpty else {
            throw ReplayKitBroadcastError.invalidDescriptor("videoTrackName must not be empty")
        }

        do {
            let session = Session(url: configuration.descriptor.relayURL)
            try await session.connect()

            let videoEncoderConfig = await resolvedScreenVideoEncoderConfig()

            let publisher = try Publisher()
            _ = publisher.addVideoTrack(
                name: configuration.videoTrackName,
                source: videoSource,
                config: videoEncoderConfig
            )
            if let appAudioTrackName = configuration.appAudioTrackName {
                _ = publisher.addAudioTrack(
                    name: appAudioTrackName,
                    source: appAudioSource,
                    config: configuration.appAudioEncoder
                )
            }
            if let micAudioTrackName = configuration.micAudioTrackName {
                _ = publisher.addAudioTrack(
                    name: micAudioTrackName,
                    source: micAudioSource,
                    config: configuration.micAudioEncoder
                )
            }

            try await session.publish(
                path: configuration.descriptor.broadcastPath,
                publisher: publisher
            )
            try await publisher.start()

            self.session = session
            self.publisher = publisher
            self.isRunning = true
        } catch {
            await stop()
            throw error
        }
    }

    /// Forwards a ReplayKit sample buffer into the active publish pipeline.
    ///
    /// Call this for every sample received by your `RPBroadcastSampleHandler`.
    public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard isRunning else { return }

        switch type {
        case .video:
            _ = videoSource.send(sampleBuffer)
        case .audioApp:
            _ = appAudioSource.send(sampleBuffer)
        case .audioMic:
            _ = micAudioSource.send(sampleBuffer)
        @unknown default:
            break
        }
    }

    /// Stops publishing and closes the relay session.
    public func stop() async {
        let publisher = self.publisher
        self.publisher = nil

        let session = self.session
        self.session = nil

        isRunning = false

        videoSource.onFrame = nil
        appAudioSource.onFrame = nil
        micAudioSource.onFrame = nil

        publisher?.stop()
        if let session {
            await session.close()
        }
    }
}

/// Base `RPBroadcastSampleHandler` that handles MoQ session + publish pipeline lifecycle.
///
/// Subclass this in your Broadcast Upload Extension when you want MoQKit to manage the
/// session and publisher lifecycle for you. Most apps only need to provide an App Group
/// identifier or override configuration lookup.
open class MoQReplayKitBroadcastSampleHandler: RPBroadcastSampleHandler {
    private final class PendingSample: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let sampleBufferType: RPSampleBufferType

        init(sampleBuffer: CMSampleBuffer, sampleBufferType: RPSampleBufferType) {
            self.sampleBuffer = sampleBuffer
            self.sampleBufferType = sampleBufferType
        }
    }

    private static let sampleBufferBacklogLimit = 256

    private var pipeline: ReplayKitBroadcastPipeline?
    private var startupTask: Task<Void, Never>?
    private var sampleBufferTask: Task<Void, Never>?
    private var sampleBufferContinuation: AsyncStream<PendingSample>.Continuation?
    private var isPaused = false

    public override init() {
        super.init()
    }

    /// Optional App Group identifier used for fallback configuration lookup.
    ///
    /// Return a value here when the host app stores a descriptor in shared defaults for
    /// the extension to pick up.
    open var replayKitAppGroupIdentifier: String? {
        nil
    }

    /// `UserDefaults` key used when reading fallback configuration from the App Group store.
    open var replayKitAppGroupDescriptorKey: String {
        ReplayKitBroadcastDescriptorStore.defaultKey
    }

    /// Setup-info key used when the broadcast UI passes a nested configuration payload.
    open var replayKitSetupInfoConfigurationKey: String {
        ReplayKitBroadcastSetupInfo.configurationKey
    }

    /// Resolves the configuration used to start publishing.
    ///
    /// Default behavior is:
    /// 1. Decode a full configuration from ReplayKit `setupInfo`.
    /// 2. Fall back to ``ReplayKitBroadcastDescriptorStore`` using the App Group values.
    ///
    /// Override this when your extension needs custom configuration assembly.
    open func makeReplayKitBroadcastConfiguration(
        setupInfo: [String: NSObject]?
    ) throws -> ReplayKitBroadcastConfiguration {
        if let config = try decodeConfigurationFromSetupInfo(setupInfo) {
            return config
        }

        guard let appGroupIdentifier = replayKitAppGroupIdentifier else {
            throw ReplayKitBroadcastError.missingConfiguration
        }

        let store = ReplayKitBroadcastDescriptorStore(
            appGroupIdentifier: appGroupIdentifier,
            key: replayKitAppGroupDescriptorKey
        )
        let descriptor = try store.load()
        return ReplayKitBroadcastConfiguration(descriptor: descriptor)
    }

    /// Converts a startup error into the `NSError` shown by ReplayKit.
    ///
    /// Override to customize user-facing error text or error domains.
    open func replayKitNSError(from error: Error) -> NSError {
        NSError(
            domain: "MoQKit.ReplayKit",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "ReplayKit publish failed: \(error.localizedDescription)"]
        )
    }

    /// Called after the MoQ publishing pipeline has started successfully.
    open func replayKitDidStartPublishing(configuration: ReplayKitBroadcastConfiguration) {}

    /// Called after the MoQ publishing pipeline has fully stopped.
    open func replayKitDidStopPublishing() {}

    /// ReplayKit entry point that starts the MoQ publishing pipeline.
    ///
    /// Apps usually customize configuration via the override hooks above rather than
    /// overriding this method directly.
    open override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startupTask?.cancel()
        stopSamplePump()
        startupTask = Task { [weak self] in
            guard let self else { return }
            var startedPipeline: ReplayKitBroadcastPipeline?
            do {
                let configuration = try makeReplayKitBroadcastConfiguration(setupInfo: setupInfo)
                try Task.checkCancellation()
                let pipeline = ReplayKitBroadcastPipeline(configuration: configuration)
                try await pipeline.start()
                startedPipeline = pipeline
                try Task.checkCancellation()
                self.pipeline = pipeline
                startSamplePump(for: pipeline)
                replayKitDidStartPublishing(configuration: configuration)
            } catch is CancellationError {
                if let startedPipeline {
                    await startedPipeline.stop()
                }
                self.pipeline = nil
                return
            } catch {
                if Task.isCancelled {
                    if let startedPipeline {
                        await startedPipeline.stop()
                    }
                    self.pipeline = nil
                    return
                }
                self.pipeline = nil
                stopSamplePump()
                finishBroadcastWithError(replayKitNSError(from: error))
            }
        }
    }

    /// ReplayKit entry point that temporarily pauses sample forwarding.
    open override func broadcastPaused() {
        isPaused = true
    }

    /// ReplayKit entry point that resumes sample forwarding after a pause.
    open override func broadcastResumed() {
        isPaused = false
    }

    /// ReplayKit entry point that stops publishing and tears down the pipeline.
    open override func broadcastFinished() {
        startupTask?.cancel()
        startupTask = nil
        stopSamplePump()

        let pipeline = self.pipeline
        self.pipeline = nil

        Task { [weak self] in
            await pipeline?.stop()
            self?.replayKitDidStopPublishing()
        }
    }

    /// ReplayKit entry point for every captured sample buffer.
    ///
    /// Apps normally do not call this directly; ReplayKit invokes it for the active
    /// Broadcast Upload extension.
    open override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard !isPaused else { return }
        sampleBufferContinuation?.yield(
            PendingSample(sampleBuffer: sampleBuffer, sampleBufferType: sampleBufferType)
        )
    }

    private func startSamplePump(for pipeline: ReplayKitBroadcastPipeline) {
        stopSamplePump()

        var continuation: AsyncStream<PendingSample>.Continuation?
        let stream = AsyncStream<PendingSample>(
            bufferingPolicy: .bufferingNewest(Self.sampleBufferBacklogLimit)
        ) { continuation = $0 }

        sampleBufferContinuation = continuation
        sampleBufferTask = Task { [weak self] in
            for await sample in stream {
                guard let self else { return }
                if self.isPaused { continue }
                await pipeline.processSampleBuffer(sample.sampleBuffer, type: sample.sampleBufferType)
            }
        }
    }

    private func stopSamplePump() {
        sampleBufferContinuation?.finish()
        sampleBufferContinuation = nil
        sampleBufferTask?.cancel()
        sampleBufferTask = nil
    }

    private func decodeConfigurationFromSetupInfo(
        _ setupInfo: [String: NSObject]?
    ) throws -> ReplayKitBroadcastConfiguration? {
        guard let setupInfo else { return nil }

        if let explicitPayload = setupInfo[replayKitSetupInfoConfigurationKey] {
            return try decodeSetupInfoConfigurationObject(explicitPayload)
        }

        // Fallback: allow top-level setupInfo dictionary when it directly matches config shape.
        if let topLevel = try? decodeSetupInfoConfigurationObject(setupInfo as NSDictionary) {
            return topLevel
        }

        return nil
    }

    private func decodeSetupInfoConfigurationObject(
        _ object: Any
    ) throws -> ReplayKitBroadcastConfiguration {
        let data: Data

        switch object {
        case let dict as NSDictionary:
            guard JSONSerialization.isValidJSONObject(dict) else {
                throw ReplayKitBroadcastError.invalidSetupInfo("Setup info dictionary is not valid JSON")
            }
            data = try JSONSerialization.data(withJSONObject: dict)
        case let str as NSString:
            guard let utf8 = str.data(using: String.Encoding.utf8.rawValue) else {
                throw ReplayKitBroadcastError.invalidSetupInfo("Setup info string is not UTF-8")
            }
            data = utf8
        case let rawData as NSData:
            data = rawData as Data
        default:
            throw ReplayKitBroadcastError.invalidSetupInfo(
                "Unsupported setup info payload type: \(type(of: object))"
            )
        }

        do {
            return try JSONDecoder().decode(ReplayKitBroadcastConfiguration.self, from: data)
        } catch {
            throw ReplayKitBroadcastError.invalidSetupInfo(error.localizedDescription)
        }
    }
}
