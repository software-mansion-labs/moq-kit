@testable import MoQKit
import Moq
import XCTest

final class ErrorsTests: XCTestCase {
    func testMapsVideoErrorMessage() {
        let error = MoqError.Video(message: "  video encoder failed  ")

        XCTAssertEqual(error.moqKitMessage, "video encoder failed")
    }
}
