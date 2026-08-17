import XCTest
@testable import AugmentMeReality

/// ADR-014: the classifier must never flap — a jog can't enter vehicular, and a
/// station stop can't exit it.
final class MotionClassifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testWalkingSpeedsNeverEnterVehicular() {
        let classifier = MotionClassifier()
        for second in 0..<120 {
            let state = classifier.update(speed: 2.0, at: t0.addingTimeInterval(Double(second)))
            XCTAssertNotEqual(state, .vehicular)
        }
        XCTAssertEqual(classifier.state, .walking)
    }

    func testVehicularRequiresSustainedSpeed() {
        let classifier = MotionClassifier()
        XCTAssertEqual(classifier.update(speed: 12, at: t0), .still, "no instant flip")
        XCTAssertEqual(classifier.update(speed: 12, at: t0.addingTimeInterval(4)), .still)
        XCTAssertEqual(classifier.update(speed: 12, at: t0.addingTimeInterval(5.5)), .vehicular)
    }

    func testVehicularStickyThroughStationStop() {
        let classifier = MotionClassifier()
        classifier.update(speed: 15, at: t0)
        classifier.update(speed: 15, at: t0.addingTimeInterval(6))
        XCTAssertEqual(classifier.state, .vehicular)

        // Train stops for 9 seconds — must stay vehicular.
        classifier.update(speed: 0, at: t0.addingTimeInterval(10))
        XCTAssertEqual(classifier.update(speed: 0, at: t0.addingTimeInterval(18)), .vehicular)

        // Still stopped past the 10 s exit dwell — now it may leave.
        XCTAssertEqual(classifier.update(speed: 0, at: t0.addingTimeInterval(21)), .still)
    }

    func testSpeedBlipDoesNotResetToVehicular() {
        let classifier = MotionClassifier()
        classifier.update(speed: 1.5, at: t0)
        classifier.update(speed: 1.5, at: t0.addingTimeInterval(4))
        XCTAssertEqual(classifier.state, .walking)
        // One noisy 8 m/s GPS sample then back to walking: no vehicular.
        classifier.update(speed: 8, at: t0.addingTimeInterval(5))
        XCTAssertEqual(classifier.update(speed: 1.5, at: t0.addingTimeInterval(6)), .walking)
    }
}
