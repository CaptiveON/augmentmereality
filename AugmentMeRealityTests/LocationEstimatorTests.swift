import CoreLocation
import XCTest
@testable import AugmentMeReality

final class LocationEstimatorTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func fix(
        east: Double, at seconds: Double, speed: Double = 0,
        course: Double = 90, accuracy: Double = 5
    ) -> CLLocation {
        let coordinate = GeoMath.coordinate(
            from: origin, bearingDegrees: east >= 0 ? 90 : 270,
            distanceMeters: abs(east)
        )
        return CLLocation(
            coordinate: coordinate, altitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 5,
            course: course, speed: speed,
            timestamp: t0.addingTimeInterval(seconds)
        )
    }

    private func east(_ coordinate: CLLocationCoordinate2D) -> Double {
        GeoMath.enuOffset(from: origin, to: coordinate).x
    }

    func testArrivalPolicyRejectsInvalidStaleFutureAndOutOfOrderFixes() {
        let now = t0.addingTimeInterval(10)
        XCTAssertTrue(LocationFixPolicy.accepts(
            fix(east: 0, at: 10), at: now, newerThan: nil
        ))
        XCTAssertFalse(LocationFixPolicy.accepts(
            fix(east: 0, at: -31), at: now, newerThan: nil
        ))
        XCTAssertFalse(LocationFixPolicy.accepts(
            fix(east: 0, at: 13), at: now, newerThan: nil
        ))
        XCTAssertFalse(LocationFixPolicy.accepts(
            fix(east: 0, at: 10), at: now,
            newerThan: t0.addingTimeInterval(10)
        ))
        XCTAssertFalse(LocationFixPolicy.accepts(
            fix(east: 0, at: 10, accuracy: -1), at: now, newerThan: nil
        ))
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 95, longitude: 0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 90, speed: 10, timestamp: now
        )
        XCTAssertFalse(LocationFixPolicy.accepts(invalid, at: now, newerThan: nil))
    }

    func testNoisyFixedAndMovingMeasurementsAreFiltered() {
        var still = TransitLocationEstimator()
        let jitter: [Double] = [0, 6, -5, 7, -8, 5, -4, 6, -7, 4]
        for (index, measuredEast) in jitter.enumerated() {
            let second = Double(index)
            XCTAssertTrue(still.ingest(
                fix(east: measuredEast, at: second),
                at: t0.addingTimeInterval(second)
            ))
        }
        let stillEstimate = try! XCTUnwrap(still.estimate(at: t0.addingTimeInterval(9)))
        XCTAssertLessThan(abs(east(stillEstimate.coordinate)), 5)

        var moving = TransitLocationEstimator()
        var largestRawStep = 0.0
        var largestFilteredStep = 0.0
        var previousRaw: Double?
        var previousFiltered: Double?
        for second in 0..<16 {
            let raw = Double(second) * 10 + (second.isMultiple(of: 2) ? 7.0 : -7.0)
            let now = t0.addingTimeInterval(Double(second))
            XCTAssertTrue(moving.ingest(
                fix(east: raw, at: Double(second), speed: 10), at: now
            ))
            let filtered = east(try! XCTUnwrap(moving.estimate(at: now)).coordinate)
            if let previousRaw, let previousFiltered {
                largestRawStep = max(largestRawStep, abs(raw - previousRaw))
                largestFilteredStep = max(largestFilteredStep,
                                          abs(filtered - previousFiltered))
            }
            previousRaw = raw
            previousFiltered = filtered
        }
        XCTAssertLessThan(largestFilteredStep, largestRawStep)
        let final = try! XCTUnwrap(moving.estimate(at: t0.addingTimeInterval(15)))
        XCTAssertLessThan(abs(east(final.coordinate) - 150), 12)
    }

    func testOutlierNeedsCorroborationAndRecoveryIsMarked() {
        var estimator = TransitLocationEstimator()
        XCTAssertTrue(estimator.ingest(fix(east: 0, at: 0), at: t0))
        let jumpAt = t0.addingTimeInterval(1)
        XCTAssertFalse(estimator.ingest(fix(east: 200, at: 1), at: jumpAt))
        XCTAssertLessThan(abs(east(try! XCTUnwrap(estimator.estimate(at: jumpAt)).coordinate)), 1)
        let confirmedAt = t0.addingTimeInterval(2)
        XCTAssertTrue(estimator.ingest(fix(east: 202, at: 2), at: confirmedAt))
        XCTAssertEqual(estimator.estimate(at: confirmedAt)?.quality, .reacquiring)
        XCTAssertEqual(estimator.estimate(at: t0.addingTimeInterval(5))?.quality, .tracking)
    }

    func testTunnelPredictionExpiresAndFreshFixRecoversWithoutReplay() {
        var estimator = TransitLocationEstimator()
        XCTAssertTrue(estimator.ingest(fix(east: 0, at: 0, speed: 20), at: t0))
        let active = try! XCTUnwrap(estimator.estimate(at: t0.addingTimeInterval(6)))
        XCTAssertEqual(active.quality, .tracking)
        XCTAssertEqual(east(active.coordinate), 120, accuracy: 0.2)

        let stale = try! XCTUnwrap(estimator.estimate(at: t0.addingTimeInterval(60)))
        XCTAssertEqual(stale.quality, .degraded)
        XCTAssertEqual(east(stale.coordinate), 160, accuracy: 0.2)
        XCTAssertEqual(stale.measurementAge, 60, accuracy: 0.01)

        let recoveredAt = t0.addingTimeInterval(61)
        XCTAssertTrue(estimator.ingest(
            fix(east: 1_220, at: 61, speed: 20), at: recoveredAt
        ))
        XCTAssertEqual(estimator.estimate(at: recoveredAt)?.quality, .reacquiring)
        XCTAssertFalse(estimator.ingest(
            fix(east: 1_200, at: 60, speed: 20), at: recoveredAt
        ))
        XCTAssertEqual(estimator.estimate(at: t0.addingTimeInterval(63))?.quality, .reacquiring)
        XCTAssertTrue(estimator.ingest(
            fix(east: 1_280, at: 64, speed: 20), at: t0.addingTimeInterval(64)
        ))
        XCTAssertEqual(estimator.estimate(at: t0.addingTimeInterval(65))?.quality, .tracking)
    }

    func testHeadingReferenceAndFreshnessStayExplicit() {
        let trueSample = HeadingSample(
            degrees: 35, timestamp: t0, accuracyDegrees: 4,
            reference: .trueNorth
        )
        XCTAssertTrue(trueSample.isCurrent(at: t0.addingTimeInterval(1)))
        XCTAssertFalse(trueSample.isCurrent(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(trueSample.reference, .trueNorth)

        let magnetic = HeadingSample(
            degrees: 35, timestamp: t0, accuracyDegrees: 4,
            reference: .magneticNorth
        )
        XCTAssertTrue(magnetic.isCurrent(at: t0))
        XCTAssertEqual(magnetic.reference, .magneticNorth)
    }
}
