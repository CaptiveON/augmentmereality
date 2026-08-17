import CoreLocation
import XCTest
@testable import AugmentMeReality

final class GeoMathTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)

    func testENUOffsetNorthRoundTrip() {
        let target = GeoMath.coordinate(from: origin, bearingDegrees: 0, distanceMeters: 100)
        let enu = GeoMath.enuOffset(from: origin, to: target)
        XCTAssertEqual(enu.y, 100, accuracy: 0.5, "100 m due north must come back as +100 north")
        XCTAssertEqual(enu.x, 0, accuracy: 0.5)
    }

    func testENUOffsetEastRoundTrip() {
        let target = GeoMath.coordinate(from: origin, bearingDegrees: 90, distanceMeters: 250)
        let enu = GeoMath.enuOffset(from: origin, to: target)
        XCTAssertEqual(enu.x, 250, accuracy: 1)
        XCTAssertEqual(enu.y, 0, accuracy: 1)
    }

    func testBearingCardinals() {
        let north = GeoMath.coordinate(from: origin, bearingDegrees: 0, distanceMeters: 500)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: north), 0, accuracy: 1)
        let southWest = GeoMath.coordinate(from: origin, bearingDegrees: 225, distanceMeters: 500)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: southWest), 225, accuracy: 1)
    }

    func testCompassPoints() {
        XCTAssertEqual(GeoMath.compassPoint(for: 0), "N")
        XCTAssertEqual(GeoMath.compassPoint(for: 44), "NE")
        XCTAssertEqual(GeoMath.compassPoint(for: 180), "S")
        XCTAssertEqual(GeoMath.compassPoint(for: 351), "N")
    }

    func testDistanceLabels() {
        XCTAssertEqual(GeoMath.distanceLabel(35.4), "35 m")
        XCTAssertEqual(GeoMath.distanceLabel(1500), "1.5 km")
    }

    // MARK: - Transit dead reckoning (ADR-015)

    private func fix(
        speed: Double, course: Double, ageSeconds: TimeInterval
    ) -> CLLocation {
        CLLocation(
            coordinate: origin,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            speed: speed,
            timestamp: Date().addingTimeInterval(-ageSeconds)
        )
    }

    func testPredictedStationaryReturnsFix() {
        let location = fix(speed: 0, course: -1, ageSeconds: 5)
        let predicted = GeoMath.predicted(from: location, at: Date())
        XCTAssertEqual(predicted.latitude, origin.latitude, accuracy: 1e-9)
        XCTAssertEqual(predicted.longitude, origin.longitude, accuracy: 1e-9)
    }

    func testPredictedAdvancesAlongCourse() {
        let location = fix(speed: 10, course: 0, ageSeconds: 5)
        let predicted = GeoMath.predicted(from: location, at: Date())
        let enu = GeoMath.enuOffset(from: origin, to: predicted)
        XCTAssertEqual(enu.y, 50, accuracy: 1, "10 m/s north for 5 s ≈ 50 m north")
        XCTAssertEqual(enu.x, 0, accuracy: 1)
    }

    func testPredictionCapsAtEightSeconds() {
        // Tunnel honesty: never extrapolate a stale fix beyond 8 s of travel.
        let location = fix(speed: 20, course: 90, ageSeconds: 60)
        let predicted = GeoMath.predicted(from: location, at: Date())
        let enu = GeoMath.enuOffset(from: origin, to: predicted)
        XCTAssertEqual(enu.x, 160, accuracy: 2, "capped at 20 m/s × 8 s = 160 m")
    }

    func testPredictedIgnoresInvalidCourse() {
        let location = fix(speed: 15, course: -1, ageSeconds: 4)
        let predicted = GeoMath.predicted(from: location, at: Date())
        XCTAssertEqual(predicted.latitude, origin.latitude, accuracy: 1e-9)
    }
}
