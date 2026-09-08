import XCTest
@testable import MoQKit

final class CaptureLifecycleTests: XCTestCase {
    func testAvailabilityEnableAndTerminalStopShareOneResourceTransition() throws {
        let lifecycle = CaptureLifecycle()
        var starts = 0
        var stops = 0
        var state: PublishedTrackState = .idle
        let binding = CaptureTrackBinding(
            enabled: true,
            start: { starts += 1; return { stops += 1 } },
            onState: { state = $0 }, onError: { XCTFail("\($0)") }, onClosed: {}
        )
        try binding.attach(to: lifecycle)
        XCTAssertEqual(starts, 0)
        lifecycle.setRunning(true)
        lifecycle.setRunning(true)
        XCTAssertEqual(starts, 1)
        try binding.setEnabled(false)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(state, .disabled)
        lifecycle.setRunning(false)
        try binding.setEnabled(true)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(starts, 1)
        lifecycle.setRunning(true)
        XCTAssertEqual(starts, 2)
        binding.stop()
        lifecycle.setRunning(false)
        lifecycle.setRunning(true)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
    }

    func testReplayFailureRetryAndCaptureClose() throws {
        let lifecycle = CaptureLifecycle()
        lifecycle.setRunning(true)
        var attempts = 0
        var stops = 0
        var closed = false
        let binding = CaptureTrackBinding(
            enabled: true,
            start: {
                attempts += 1
                if attempts == 1 { throw SessionError.invalidConfiguration("encoder unavailable") }
                return { stops += 1 }
            },
            onState: { _ in }, onError: { _ in }, onClosed: { closed = true }
        )
        XCTAssertThrowsError(try binding.attach(to: lifecycle))
        XCTAssertEqual(attempts, 1)
        try binding.setEnabled(true)
        XCTAssertEqual(attempts, 2)
        try binding.setEnabled(true)
        XCTAssertEqual(attempts, 2)
        lifecycle.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(stops, 1)
        XCTAssertThrowsError(try binding.setEnabled(true))
    }
}
