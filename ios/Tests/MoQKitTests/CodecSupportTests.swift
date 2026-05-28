@testable import MoQKit
import MoqFFI
import XCTest

final class VideoCodecSupportTests: XCTestCase {
    func testKnownVideoCodecPrefixesArePlayable() {
        for codec in ["avc1", "avc3", "hev1", "hvc1", "av01"] {
            let track = makeVideoTrack(codec: codec)

            XCTAssertTrue(track.isPlayable, "\(codec) should be playable by codec name")
            XCTAssertNil(track.unsupportedReason)
        }
    }

    func testUnknownVideoCodecIsNotPlayable() {
        let track = makeVideoTrack(codec: "vp09")

        XCTAssertFalse(track.isPlayable)
        XCTAssertEqual(track.unsupportedReason, "Unsupported video codec: vp09")
    }

    private func makeVideoTrack(codec: String) -> VideoTrackInfo {
        VideoTrackInfo(
            name: "video-\(codec)",
            config: MoqVideo(
                codec: codec,
                description: nil,
                coded: nil,
                displayRatio: nil,
                bitrate: nil,
                framerate: nil,
                container: .legacy
            )
        )
    }
}
