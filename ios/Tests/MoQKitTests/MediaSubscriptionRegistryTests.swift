import Foundation
import MoqFFI
@testable import MoQKit
import XCTest

final class MediaSubscriptionRegistryTests: XCTestCase {
    func testMediaContainerConvertsToRawContainer() {
        XCTAssertEqual(MediaContainer(.legacy), .legacy)
        XCTAssertEqual(MediaContainer(.loc), .loc)

        let initData = Data([0x01, 0x02])
        XCTAssertEqual(MediaContainer(.cmaf(init: initData)), .cmaf(initializationData: initData))

        XCTAssertEqual(MediaContainer.legacy.rawContainer, .legacy)
        XCTAssertEqual(MediaContainer.loc.rawContainer, .loc)
        XCTAssertEqual(MediaContainer.cmaf(initializationData: initData).rawContainer, .cmaf(init: initData))
    }

    func testCatalogMediaSourceUsesCatalogTrackMetadata() throws {
        let audioConsumer = FakeMoqMediaConsumer()
        let videoConsumer = FakeMoqMediaConsumer()
        let rawBroadcast = FakeMoqBroadcastConsumer(consumers: [audioConsumer, videoConsumer])
        let catalog = Catalog(
            path: "live/test",
            catalog: MoqCatalog(
                video: [
                    "video": MoqVideo(
                        codec: "avc1",
                        description: nil,
                        coded: nil,
                        displayRatio: nil,
                        bitrate: nil,
                        framerate: nil,
                        container: .loc
                    )
                ],
                audio: [
                    "audio": MoqAudio(
                        codec: "opus",
                        description: nil,
                        sampleRate: 48_000,
                        channelCount: 2,
                        bitrate: nil,
                        container: .legacy
                    )
                ],
                display: nil,
                rotation: nil,
                flip: nil,
                extra: [:]
            ),
            mediaSource: BroadcastMediaSource(consumer: rawBroadcast)
        )
        let audioTrack = try XCTUnwrap(catalog.audioTracks.first { $0.name == "audio" })
        let videoTrack = try XCTUnwrap(catalog.videoTracks.first { $0.name == "video" })

        let audioSubscription = try catalog.mediaSource.subscribeMedia(
            MediaTrackRequest(
                track: audioTrack,
                targetBuffering: .milliseconds(125)
            )
        )
        let videoSubscription = try catalog.mediaSource.subscribeMedia(
            MediaTrackRequest(
                track: videoTrack,
                targetBuffering: .milliseconds(250)
            )
        )

        XCTAssertEqual(rawBroadcast.requestNames, ["audio", "video"])
        XCTAssertEqual(rawBroadcast.requestContainers, [.legacy, .loc])
        XCTAssertEqual(rawBroadcast.maxLatencyMsValues, [125, 250])

        audioSubscription.close()
        videoSubscription.close()
    }

    @MainActor
    func testPlayerRejectsUnknownCatalogAudioTrack() throws {
        let catalog = makeCatalog(path: "live/test")

        XCTAssertThrowsError(
            try Player(
                catalog: catalog,
                audioTrackName: "missing"
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionError,
                .invalidConfiguration(
                    "Unknown audio track 'missing' for catalog live/test"
                )
            )
        }
    }

    func testAudioDataStreamRejectsUnknownCatalogAudioTrack() throws {
        let catalog = makeCatalog(path: "live/test")

        XCTAssertThrowsError(
            try AudioDataStream(
                catalog: catalog,
                trackName: "missing"
            )
        ) { error in
            XCTAssertEqual(
                error as? SessionError,
                .invalidConfiguration(
                    "Unknown audio track 'missing' for catalog 'live/test'"
                )
            )
        }
    }

    func testSubscribersShareOneUpstreamAndReceiveTheSameFrames() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let first = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let second = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(250)
            )
        )
        let firstFrames = MediaFrameIterator(first.frames)
        let secondFrames = MediaFrameIterator(second.frames)

        let firstTask = Task { try await firstFrames.next() }
        let secondTask = Task { try await secondFrames.next() }
        consumer.yield(makeMoqFrame(timestampUs: 42))

        let firstFrame = try await taskValue(of: firstTask)
        let secondFrame = try await taskValue(of: secondTask)
        XCTAssertEqual(firstFrame?.timestampUs, 42)
        XCTAssertEqual(secondFrame?.timestampUs, 42)
        XCTAssertEqual(broadcast.subscribeMediaCallCount, 1)
        XCTAssertEqual(broadcast.maxLatencyMsValues, [100])

        first.close()
        second.close()
    }

    func testClosingOneSubscriberKeepsOtherSubscriberActive() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let first = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let second = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let secondFrames = MediaFrameIterator(second.frames)

        first.close()
        XCTAssertEqual(consumer.cancelCallCount, 0)

        let secondTask = Task { try await secondFrames.next() }
        consumer.yield(makeMoqFrame(timestampUs: 7))

        let secondFrame = try await taskValue(of: secondTask)
        XCTAssertEqual(secondFrame?.timestampUs, 7)
        XCTAssertEqual(broadcast.subscribeMediaCallCount, 1)
        XCTAssertEqual(consumer.cancelCallCount, 0)

        second.close()
        XCTAssertEqual(consumer.cancelCallCount, 1)
    }

    func testLastSubscriberCloseCancelsAndEvictsUpstream() throws {
        let firstConsumer = FakeMoqMediaConsumer()
        let secondConsumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [firstConsumer, secondConsumer])
        let registry = makeRegistry(broadcast: broadcast)

        let first = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        first.close()

        XCTAssertEqual(firstConsumer.cancelCallCount, 1)
        XCTAssertEqual(broadcast.subscribeMediaCallCount, 1)
        XCTAssertEqual(registry.activeSubscriptionCount, 0)

        let second = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        second.close()

        XCTAssertEqual(secondConsumer.cancelCallCount, 1)
        XCTAssertEqual(broadcast.subscribeMediaCallCount, 2)
        XCTAssertEqual(registry.activeSubscriptionCount, 0)
    }

    func testUpstreamEndFinishesAllSubscribersAndEvictsUpstream() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let first = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let second = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let firstFrames = MediaFrameIterator(first.frames)
        let secondFrames = MediaFrameIterator(second.frames)

        let firstTask = Task { try await firstFrames.next() }
        let secondTask = Task { try await secondFrames.next() }
        consumer.finish()

        let firstFrame = try await taskValue(of: firstTask)
        let secondFrame = try await taskValue(of: secondTask)
        XCTAssertNil(firstFrame)
        XCTAssertNil(secondFrame)
        XCTAssertEqual(consumer.cancelCallCount, 0)
        XCTAssertEqual(registry.activeSubscriptionCount, 0)
    }

    func testUpstreamErrorFinishesAllSubscribersWithError() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let first = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let second = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let firstFrames = MediaFrameIterator(first.frames)
        let secondFrames = MediaFrameIterator(second.frames)

        let firstTask = Task { try await firstFrames.next() }
        let secondTask = Task { try await secondFrames.next() }
        consumer.fail(MediaSubscriptionTestError.upstreamFailed)

        try await assertTaskThrowsUpstreamFailure(firstTask)
        try await assertTaskThrowsUpstreamFailure(secondTask)
        XCTAssertEqual(registry.activeSubscriptionCount, 0)
    }

    func testMediaTrackWrapsFrameStreamWithoutCatalog() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let media = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "off-catalog-audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let track = MediaTrack(media: media)
        let frames = MediaFrameIterator(track.frames)

        let frameTask = Task { try await frames.next() }
        consumer.yield(makeMoqFrame(timestampUs: 101))

        let frame = try await taskValue(of: frameTask)
        XCTAssertEqual(frame?.timestampUs, 101)

        track.close()
    }

    func testMediaTrackFramesThrowOnUpstreamError() async throws {
        let consumer = FakeMoqMediaConsumer()
        let broadcast = FakeMoqBroadcastConsumer(consumers: [consumer])
        let registry = makeRegistry(broadcast: broadcast)

        let media = try registry.subscribeMedia(
            MediaTrackRequest(
                name: "audio",
                container: .legacy,
                targetBuffering: .milliseconds(100)
            )
        )
        let track = MediaTrack(media: media)
        let frames = MediaFrameIterator(track.frames)

        let frameTask = Task { try await frames.next() }
        consumer.fail(MediaSubscriptionTestError.upstreamFailed)

        try await assertTaskThrowsUpstreamFailure(frameTask)
    }
}

private func makeCatalog(path: String) -> Catalog {
    Catalog(
        path: path,
        catalog: MoqCatalog(
            video: [:],
            audio: [
                "audio": MoqAudio(
                    codec: "opus",
                    description: nil,
                    sampleRate: 48_000,
                    channelCount: 2,
                    bitrate: nil,
                    container: .legacy
                )
            ],
            display: nil,
            rotation: nil,
            flip: nil,
            extra: [:]
        ),
        mediaSource: BroadcastMediaSource(consumer: FakeMoqBroadcastConsumer(consumers: []))
    )
}

private final class MediaFrameIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<MediaFrame, Error>.Iterator

    init(_ stream: AsyncThrowingStream<MediaFrame, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> MediaFrame? {
        try await iterator.next()
    }
}

private final class FakeMoqBroadcastConsumer: MoqBroadcastConsumer, @unchecked Sendable {
    private struct Request {
        let name: String
        let container: Container
        let maxLatencyMs: UInt64
    }

    private let lock = NSLock()
    private var consumers: [FakeMoqMediaConsumer]
    private var requests: [Request] = []

    init(consumers: [FakeMoqMediaConsumer]) {
        self.consumers = consumers
        super.init(noHandle: MoqBroadcastConsumer.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        self.consumers = []
        super.init(unsafeFromHandle: handle)
    }

    var subscribeMediaCallCount: Int {
        lock.withLock { requests.count }
    }

    var maxLatencyMsValues: [UInt64] {
        lock.withLock { requests.map(\.maxLatencyMs) }
    }

    var requestNames: [String] {
        lock.withLock { requests.map(\.name) }
    }

    var requestContainers: [Container] {
        lock.withLock { requests.map(\.container) }
    }

    override func subscribeMedia(
        name: String,
        container: Container,
        maxLatencyMs: UInt64
    ) throws -> MoqMediaConsumer {
        lock.withLock {
            requests.append(
                Request(
                    name: name,
                    container: container,
                    maxLatencyMs: maxLatencyMs
                )
            )
            return consumers.removeFirst()
        }
    }
}

private final class FakeMoqMediaConsumer: MoqMediaConsumer, @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<MoqFrame?, Error>

    private let lock = NSLock()
    private var queuedResults: [Result<MoqFrame?, Error>] = []
    private var continuations: [Continuation] = []
    private var cancelCount = 0

    var cancelCallCount: Int {
        lock.withLock { cancelCount }
    }

    init() {
        super.init(noHandle: MoqMediaConsumer.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        super.init(unsafeFromHandle: handle)
    }

    override func cancel() {
        let continuations = lock.withLock {
            cancelCount += 1
            let continuations = self.continuations
            self.continuations.removeAll()
            return continuations
        }

        continuations.forEach { $0.resume(returning: nil) }
    }

    override func next() async throws -> MoqFrame? {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<MoqFrame?, Error>? in
                guard !queuedResults.isEmpty else {
                    continuations.append(continuation)
                    return nil
                }
                return queuedResults.removeFirst()
            }

            guard let result else { return }
            resume(continuation, with: result)
        }
    }

    func yield(_ frame: MoqFrame) {
        send(.success(frame))
    }

    func fail(_ error: Error) {
        send(.failure(error))
    }

    func finish() {
        send(.success(nil))
    }

    private func send(_ result: Result<MoqFrame?, Error>) {
        let continuation = lock.withLock { () -> Continuation? in
            guard !continuations.isEmpty else {
                queuedResults.append(result)
                return nil
            }
            return continuations.removeFirst()
        }

        guard let continuation else { return }
        resume(continuation, with: result)
    }

    private func resume(_ continuation: Continuation, with result: Result<MoqFrame?, Error>) {
        switch result {
        case .success(let frame):
            continuation.resume(returning: frame)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private enum MediaSubscriptionTestError: Error, Equatable {
    case timeout
    case upstreamFailed
}

private func makeMoqFrame(timestampUs: UInt64) -> MoqFrame {
    MoqFrame(
        payload: Data([0x01, 0x02, 0x03]),
        timestampUs: timestampUs,
        keyframe: true
    )
}

private func makeRegistry(broadcast: FakeMoqBroadcastConsumer) -> MediaSubscriptionRegistry {
    MediaSubscriptionRegistry(broadcast: broadcast)
}

private func taskValue<T>(
    of task: Task<T, Error>,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw MediaSubscriptionTestError.timeout
        }
        defer { group.cancelAll() }

        let next = try await group.next()
        let value = try XCTUnwrap(
            next,
            file: file,
            line: line
        )
        return value
    }
}

private func assertTaskThrowsUpstreamFailure<T>(
    _ task: Task<T, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    do {
        _ = try await taskValue(of: task, file: file, line: line)
        XCTFail("Expected upstream failure", file: file, line: line)
    } catch MediaSubscriptionTestError.upstreamFailed {
        return
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}
