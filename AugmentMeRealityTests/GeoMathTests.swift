import CoreLocation
import XCTest
@testable import AugmentMeReality

final class GeoMathTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)

    // Independent WGS84 Vincenty-direct oracle, generated outside GeoMath.
    // Columns: origin latitude/longitude, true azimuth, distance, destination.
    // Coordinate tolerance 3e-6 degree (<0.34 m); tangent ENU tolerance 0.2 m.
    private let geodesicFixtures: [(
        Double, Double, Double, Double, Double, Double
    )] = [
        (0, 0, 0, 1_000, 0.0090436947696644, 0),
        (0, 0, 90, 2_000, 0, 0.0179663056823927),
        (37, -122, 45, 2_000, 37.01274215218457, -121.98410939160446),
        (45, 7, 180, 5_000, 44.95500819031675, 7),
        (70, 20, 270, 2_000, 69.99999230043157, 19.94762553922675),
        (-33.86, 151.21, 135, 5_000, -33.891868662068156, 151.24822129225396),
        (0.5, 179.995, 90, 2_000, 0.4999999752520061, -179.98703301476945),
        (80, -179.98, 315, 5_000, 80.03161360891959, 179.83712230348385)
    ]

    func testCheckedGeodesyAgainstIndependentWGS84Fixtures() {
        for (lat, lon, azimuth, distance, expectedLat, expectedLon) in geodesicFixtures {
            let start = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let expected = CLLocationCoordinate2D(latitude: expectedLat, longitude: expectedLon)
            let actual = try! XCTUnwrap(GeoMath.checkedCoordinate(
                from: start, bearingDegrees: azimuth, distanceMeters: distance
            ))
            XCTAssertEqual(actual.latitude, expectedLat, accuracy: 3e-6)
            XCTAssertEqual(actual.longitude, expectedLon, accuracy: 3e-6)

            let enu = try! XCTUnwrap(GeoMath.checkedENUOffset(from: start, to: expected))
            XCTAssertEqual(enu.x, distance * sin(azimuth * .pi / 180), accuracy: 0.2)
            XCTAssertEqual(enu.y, distance * cos(azimuth * .pi / 180), accuracy: 0.2)
            XCTAssertEqual(try! XCTUnwrap(GeoMath.checkedBearing(from: start, to: expected)),
                           azimuth, accuracy: 0.03)
        }
    }

    func testInvalidAndOutOfRangeCoordinatesFailCheckedOperations() {
        let invalid = [
            CLLocationCoordinate2D(latitude: 91, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 181),
            CLLocationCoordinate2D(latitude: .nan, longitude: 0)
        ]
        for coordinate in invalid {
            XCTAssertNil(GeoMath.checkedENUOffset(from: origin, to: coordinate))
            XCTAssertNil(GeoMath.checkedCoordinate(
                from: coordinate, bearingDegrees: 0, distanceMeters: 10
            ))
        }
        XCTAssertNil(GeoMath.checkedCoordinate(
            from: origin, bearingDegrees: 0, distanceMeters: 5_001
        ))
        XCTAssertNil(GeoMath.checkedCoordinate(
            from: origin, bearingDegrees: 0, distanceMeters: -1
        ))
        XCTAssertNil(GeoMath.checkedENUOffset(
            from: origin,
            to: CLLocationCoordinate2D(latitude: 38, longitude: -122)
        ))
    }

    func testPoleUsesADefinedLocalEastNorthFrame() {
        let pole = CLLocationCoordinate2D(latitude: 90, longitude: 45)
        let target = try! XCTUnwrap(GeoMath.checkedCoordinate(
            from: pole, bearingDegrees: 90, distanceMeters: 100
        ))
        let offset = try! XCTUnwrap(GeoMath.checkedENUOffset(from: pole, to: target))
        XCTAssertEqual(offset.x, 100, accuracy: 0.01)
        XCTAssertEqual(offset.y, 0, accuracy: 0.01)
        XCTAssertTrue(GeoMath.isValid(target))
    }

    func testARAndGPSDriftShareSavedBasisAtCardinalRotations() {
        let gps = SIMD2<Double>(6, 8) // a ten-metre diagonal walk
        let cases: [(Double, SIMD2<Double>)] = [
            (0, SIMD2(6, 8)),
            (.pi / 2, SIMD2(-8, 6)),
            (.pi, SIMD2(-6, -8)),
            (3 * .pi / 2, SIMD2(8, -6))
        ]
        for (basisHeading, ar) in cases {
            XCTAssertEqual(try! XCTUnwrap(GeoMath.driftMeters(
                gpsENU: gps, arHorizontal: ar,
                basisHeadingCorrection: basisHeading
            )), 0, accuracy: 1e-10)
            XCTAssertEqual(try! XCTUnwrap(GeoMath.driftMeters(
                gpsENU: gps, arHorizontal: ar + SIMD2(3, 4),
                basisHeadingCorrection: basisHeading
            )), 5, accuracy: 1e-10)
        }

        // A valid basis reset captures the *new* heading. A later live heading
        // update must not be used retroactively with the old camera position.
        let resetAR = SIMD2<Double>(-8, 6)
        XCTAssertEqual(try! XCTUnwrap(GeoMath.driftMeters(
            gpsENU: gps, arHorizontal: resetAR,
            basisHeadingCorrection: .pi / 2
        )), 0, accuracy: 1e-10)
    }

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
