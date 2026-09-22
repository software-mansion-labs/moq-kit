import Foundation
import os

extension DVR {
    final class HLSOrigin: @unchecked Sendable {
        let multivariantPlaylistURL: URL

        private let server: DVR.HTTPServer
        private let coordinator: DVR.SegmentCoordinator

        private init(
            multivariantPlaylistURL: URL,
            server: DVR.HTTPServer,
            coordinator: DVR.SegmentCoordinator
        ) {
            self.multivariantPlaylistURL = multivariantPlaylistURL
            self.server = server
            self.coordinator = coordinator
        }

        static func start(
            coordinator: DVR.SegmentCoordinator,
            videoCodec: String,
            audioCodec: String,
            bandwidth: UInt64?
        ) async throws -> DVR.HLSOrigin {
            let token = UUID().uuidString.lowercased()
            let plan = coordinator.plan
            let router = HLSRouter(
                token: token,
                multivariant: DVR.HLSManifest.multivariantPlaylist(
                    videoCodec: videoCodec,
                    audioCodec: audioCodec,
                    bandwidth: bandwidth
                ),
                video: DVR.HLSManifest.mediaPlaylist(
                    kind: .video,
                    segments: plan.segments,
                    initializationURI: "video-init.mp4"
                ),
                audio: DVR.HLSManifest.mediaPlaylist(
                    kind: .audio,
                    segments: plan.segments,
                    initializationURI: "audio-init.mp4"
                ),
                coordinator: coordinator
            )
            let server = try DVR.HTTPServer { request in
                await router.response(for: request)
            }
            let port = try await server.start()
            let url = URL(string: "http://localhost:\(port)/\(token)/multivariant.m3u8")!
            KitLogger.dvr.debug(
                "DVR HLS presentation ready segments=\(plan.segments.count) durationUs=\(plan.durationUs) host=localhost port=\(port)"
            )
            return DVR.HLSOrigin(
                multivariantPlaylistURL: url,
                server: server,
                coordinator: coordinator
            )
        }

        func stop() {
            server.stop()
            coordinator.cancel()
        }

        deinit {
            stop()
        }
    }
}

private actor HLSRouter {
    private let prefix: String
    private let multivariant: Data
    private let video: Data
    private let audio: Data
    private let coordinator: DVR.SegmentCoordinator

    init(
        token: String,
        multivariant: String,
        video: String,
        audio: String,
        coordinator: DVR.SegmentCoordinator
    ) {
        self.prefix = "/\(token)/"
        self.multivariant = Data(multivariant.utf8)
        self.video = Data(video.utf8)
        self.audio = Data(audio.utf8)
        self.coordinator = coordinator
    }

    func response(for request: DVR.HTTPServer.Request) async -> DVR.HTTPServer.Response {
        guard request.path.hasPrefix(prefix) else { return .notFound }
        let resource = String(request.path.dropFirst(prefix.count))
        switch resource {
        case "multivariant.m3u8":
            return .ok(contentType: "application/vnd.apple.mpegurl", body: multivariant)
        case "video.m3u8":
            return .ok(contentType: "application/vnd.apple.mpegurl", body: video)
        case "audio.m3u8":
            return .ok(contentType: "application/vnd.apple.mpegurl", body: audio)
        case "video-init.mp4":
            return .ok(
                contentType: "video/mp4",
                body: coordinator.videoInitialization,
                cacheControl: "public, max-age=31536000, immutable"
            )
        case "audio-init.mp4":
            return .ok(
                contentType: "audio/mp4",
                body: coordinator.audioInitialization,
                cacheControl: "public, max-age=31536000, immutable"
            )
        default:
            guard let route = Self.segmentRoute(resource) else { return .notFound }
            do {
                let data = try await coordinator.segment(kind: route.kind, index: route.index)
                return .ok(
                    contentType: "video/iso.segment",
                    body: data,
                    cacheControl: "public, max-age=31536000, immutable"
                )
            } catch {
                KitLogger.dvr.error(
                    "DVR HLS segment failed kind=\(route.kind.rawValue, privacy: .public) index=\(route.index) error=\(error.localizedDescription, privacy: .public)"
                )
                return .serverError
            }
        }
    }

    private static func segmentRoute(_ resource: String) -> (kind: DVR.MediaKind, index: Int)? {
        let parts = resource.split(separator: "/")
        guard parts.count == 2,
            let kind = DVR.MediaKind(rawValue: String(parts[0])),
            parts[1].hasSuffix(".m4s"),
            let index = Int(parts[1].dropLast(4)),
            index >= 0
        else { return nil }
        return (kind, index)
    }
}
