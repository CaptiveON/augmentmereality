import XCTest
@testable import AugmentMeReality

final class CaptureSubmissionGateTests: XCTestCase {
    func testRenderAndTimerCannotSubmitSameCaptureOrOlderFrame() {
        var gate = CaptureSubmissionGate()
        XCTAssertTrue(gate.admit(10))
        XCTAssertFalse(gate.admit(10))
        XCTAssertFalse(gate.admit(9))
        XCTAssertTrue(gate.admit(10.033))
    }

    func testInvalidTimestampsDoNotPoisonSubsequentAdmission() {
        var gate = CaptureSubmissionGate()
        for timestamp in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertFalse(gate.admit(timestamp))
        }
        XCTAssertTrue(gate.admit(1))
    }

    func testNewSDKSessionCanStartNewCaptureHistory() {
        var gate = CaptureSubmissionGate()
        XCTAssertTrue(gate.admit(50))
        gate.reset()
        XCTAssertTrue(gate.admit(20))
    }
}
