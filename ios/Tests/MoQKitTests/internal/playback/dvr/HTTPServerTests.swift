import Foundation
import Moq
import XCTest

@testable import MoQKit

final class HTTPServerTests: XCTestCase {
    func testParserIgnoresQueryAndRejectsMalformedRequest() {
        XCTAssertEqual(
            DVR.HTTPServer.parse(Data("GET /session/multivariant.m3u8?cache=1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)),
            DVR.HTTPServer.Request(method: "GET", path: "/session/multivariant.m3u8")
        )
        XCTAssertNil(DVR.HTTPServer.parse(Data("not-http\r\n\r\n".utf8)))
    }

    func testLoopbackServerServesGETAndHEADWithExactLength() async throws {
        let body = Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
        let server = try DVR.HTTPServer { request in
            request.path == "/playlist.m3u8"
                ? .ok(contentType: "application/vnd.apple.mpegurl", body: body)
                : .notFound
        }
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://localhost:\(port)/playlist.m3u8")!

        let (getData, getResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual(getData, body)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "\(body.count)")

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        let (headData, headResponse) = try await URLSession.shared.data(for: headRequest)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "\(body.count)")
    }

    func testHLSOriginServesTokenizedPresentationAndLazySegments() async throws {
        let plan = try DVR.HLSPlan(
            selection: DVR.Selection(
                video: DVR.TrackSelection(
                    name: "video",
                    timeline: [
                        .init(group: 10, timestampUs: 10_000_000),
                        .init(group: 11, timestampUs: 11_000_000),
                    ]),
                audio: DVR.TrackSelection(
                    name: "audio",
                    timeline: [
                        .init(group: 100, timestampUs: 10_000_000),
                        .init(group: 101, timestampUs: 11_000_000),
                    ])
            ))
        let requests = OriginRequests()
        let coordinator = try DVR.SegmentCoordinator(
            plan: plan,
            video: DVR.FetchTrack(name: "video", config: Self.videoConfig),
            audio: DVR.FetchTrack(name: "audio", config: Self.audioConfig),
            fetcher: DVR.MediaGroupFetcher { track, group, _ in
                await requests.append(track: track, group: group)
                if track == "video" {
                    return [
                        Moq.MediaFrame(payload: Data("key".utf8), timestampUs: 10_000_000, keyframe: true),
                        Moq.MediaFrame(payload: Data("delta".utf8), timestampUs: 10_033_000, keyframe: false),
                    ]
                }
                return [Moq.MediaFrame(payload: Data([0x78, 0]), timestampUs: 10_020_000, keyframe: true)]
            }
        )
        let origin = try await DVR.HLSOrigin.start(
            coordinator: coordinator,
            videoCodec: Self.videoConfig.codec,
            audioCodec: Self.audioConfig.codec,
            bandwidth: nil
        )
        defer { origin.stop() }

        let baseURL = origin.multivariantPlaylistURL.deletingLastPathComponent()
        let (multivariant, multivariantResponse) = try await URLSession.shared.data(
            from: origin.multivariantPlaylistURL
        )
        XCTAssertEqual((multivariantResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: multivariant, as: UTF8.self).contains("video.m3u8"))

        let (videoPlaylist, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("video.m3u8"))
        XCTAssertTrue(String(decoding: videoPlaylist, as: UTF8.self).contains("video/0.m4s"))

        let (videoInit, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("video-init.mp4"))
        XCTAssertEqual(videoInit.subdata(in: 4..<8), Data("ftyp".utf8))

        let (videoSegment, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("video/0.m4s"))
        let (audioSegment, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("audio/0.m4s"))
        XCTAssertEqual(videoSegment.subdata(in: 4..<8), Data("moof".utf8))
        XCTAssertEqual(audioSegment.subdata(in: 4..<8), Data("moof".utf8))
        let requestedGroups = await requests.values
        XCTAssertEqual(
            requestedGroups,
            [
                OriginRequests.Value(track: "video", group: 10),
                OriginRequests.Value(track: "audio", group: 100),
            ])

        let invalidURL = URL(
            string: "http://localhost:\(origin.multivariantPlaylistURL.port!)/invalid/multivariant.m3u8"
        )!
        let (_, invalidResponse) = try await URLSession.shared.data(from: invalidURL)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    private static let videoConfig = Moq.Video(
        codec: "vp09.00.10.08",
        description: nil,
        coded: nil,
        displayAspect: nil,
        bitrate: nil,
        framerate: 30,
        container: .legacy,
        timeline: nil
    )

    private static let audioConfig = Moq.Audio(
        codec: "opus",
        description: nil,
        sampleRate: 48_000,
        channelCount: 2,
        bitrate: nil,
        container: .legacy,
        timeline: nil
    )
}

private actor OriginRequests {
    struct Value: Sendable, Equatable {
        let track: String
        let group: UInt64
    }

    private(set) var values: [Value] = []

    func append(track: String, group: UInt64) {
        values.append(Value(track: track, group: group))
    }
}
