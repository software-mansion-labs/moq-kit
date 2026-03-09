import Foundation

public final class MoQOrigin: Sendable {
    public let handle: UInt32

    public init() throws {
        self.handle = try moqOriginCreate()
    }

    public func publish(_ broadcast: UInt32, path: String) throws {
        try moqOriginPublish(origin: handle, path: path, broadcast: broadcast)
    }

    public func consume(path: String) throws -> UInt32 {
        try moqOriginConsume(origin: handle, path: path)
    }

    public func announced() throws -> MoQAnnouncedSubscription {
        try MoQAnnouncedSubscription(originHandle: handle)
    }

    public func close() throws {
        try moqOriginClose(origin: handle)
    }

    deinit {
        try? moqOriginClose(origin: handle)
    }
}

// MARK: - Announced Subscription

public final class MoQAnnouncedSubscription: Sendable {
    public let announcements: AsyncStream<AnnouncedInfo>
    private let bridgingTask: Task<Void, Never>
    private let rawContinuation: AsyncStream<Int32>.Continuation
    private let announcedHandle: UInt32

    init(originHandle: UInt32) throws {
        var rawCont: AsyncStream<Int32>.Continuation!
        let rawStream = AsyncStream<Int32> { rawCont = $0 }

        let cb = AnnounceCB(continuation: rawCont)
        let handle = try moqOriginAnnounced(origin: originHandle, callback: cb)

        var infoCont: AsyncStream<AnnouncedInfo>.Continuation!
        let infoStream = AsyncStream<AnnouncedInfo> { infoCont = $0 }

        self.announcements = infoStream
        self.rawContinuation = rawCont
        self.announcedHandle = handle

        let capturedRawCont = rawCont!
        infoCont.onTermination = { @Sendable _ in
            capturedRawCont.finish()
        }

        rawCont.onTermination = { @Sendable _ in
            try? moqOriginAnnouncedClose(announced: handle)
        }

        bridgingTask = Task.detached {
            defer { infoCont.finish() }

            for await rawId in rawStream {
                if Task.isCancelled { break }

                if rawId <= 0 {
                    // 0 = closed, < 0 = error
                    break
                }

                let announcedId = UInt32(bitPattern: rawId)
                guard let info = try? moqOriginAnnouncedInfo(announced: announcedId) else { continue }
                infoCont.yield(info)
            }
        }
    }

    public func close() {
        bridgingTask.cancel()
        rawContinuation.finish()
    }

    deinit {
        bridgingTask.cancel()
        rawContinuation.finish()
    }
}

// MARK: - Announce Callback

private final class AnnounceCB: AnnounceCallback {
    private let continuation: AsyncStream<Int32>.Continuation

    init(continuation: AsyncStream<Int32>.Continuation) {
        self.continuation = continuation
    }

    func onAnnounce(announcedId: Int32) {
        continuation.yield(announcedId)
    }
}
