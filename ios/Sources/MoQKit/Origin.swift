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

    public func announced() throws -> AsyncStream<AnnouncedInfo> {
        // Inner stream: raw IDs only, fed by callback (no Rust calls inside callback)
        var rawCont: AsyncStream<UInt32>.Continuation!
        let rawStream = AsyncStream<UInt32> { rawCont = $0 }

        let cb = AnnounceCB(continuation: rawCont)
        let announcedHandle = try moqOriginAnnounced(origin: handle, callback: cb)

        rawCont.onTermination = { @Sendable _ in
            try? moqOriginAnnouncedClose(announced: announcedHandle)
        }

        // Outer stream: AnnouncedInfo fetched outside the callback lock
        var infoCont: AsyncStream<AnnouncedInfo>.Continuation!
        let infoStream = AsyncStream<AnnouncedInfo> { infoCont = $0 }

        // When the consumer stops, finish rawStream → fires rawCont.onTermination → closes handle
        let capturedRaw = rawCont!
        infoCont.onTermination = { @Sendable _ in capturedRaw.finish() }

        Task.detached {
            for await rawId in rawStream {
                guard let info = try? moqOriginAnnouncedInfo(announced: rawId) else { continue }
                infoCont.yield(info)
            }
            infoCont.finish()
        }

        return infoStream
    }

    public func close() throws {
        try moqOriginClose(origin: handle)
    }

    deinit {
        try? moqOriginClose(origin: handle)
    }
}

private final class AnnounceCB: AnnounceCallback {
    private let continuation: AsyncStream<UInt32>.Continuation

    init(continuation: AsyncStream<UInt32>.Continuation) {
        self.continuation = continuation
    }

    func onAnnounce(announcedId: Int32) {
        continuation.yield(UInt32(bitPattern: announcedId))   // only safe: no Rust call inside callback
    }
}
