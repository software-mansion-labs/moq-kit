import Foundation
import Moq
@testable import MoQKit
import XCTest

final class MediaTrackTests: XCTestCase {
    func testMediaContainerConvertsToMoqContainer() {
        XCTAssertEqual(MediaContainer(.legacy), .legacy)
        XCTAssertEqual(MediaContainer(.loc), .loc)

        let initializationData = Data([0x01, 0x02])
        XCTAssertEqual(
            MediaContainer(.cmaf(init: initializationData)),
            .cmaf(initializationData: initializationData)
        )

        XCTAssertEqual(MediaContainer.legacy.rawContainer, .legacy)
        XCTAssertEqual(MediaContainer.loc.rawContainer, .loc)
        XCTAssertEqual(
            MediaContainer.cmaf(initializationData: initializationData).rawContainer,
            .cmaf(init: initializationData)
        )
    }
}

final class CatalogTrackValidationTests: XCTestCase {
    @MainActor
    func testPlayerRejectsUnknownCatalogAudioTrack() throws {
        let catalog = try makeCatalog(path: "live/test")

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
        let catalog = try makeCatalog(path: "live/test")

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

    private func makeCatalog(path: String) throws -> MoQKit.Catalog {
        let producer = try Moq.BroadcastProducer()
        return Catalog(
            path: path,
            catalog: Moq.Catalog(
                video: [:],
                audio: [
                    "audio": Moq.Audio(
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
                sections: [:]
            ),
            mediaSource: BroadcastMediaSource(consumer: try producer.consume())
        )
    }
}
