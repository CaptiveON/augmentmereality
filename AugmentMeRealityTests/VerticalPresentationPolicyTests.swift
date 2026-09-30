import XCTest
@testable import AugmentMeReality

final class VerticalPresentationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSameDatumPreservesElevatedSupportAcrossViewerElevations() throws {
        let vertical = try XCTUnwrap(VerticalPresentationPolicy.publishableSupport(
            altitudeWGS84: 120, uncertainty: 1, measuredAt: now, now: now))
        for viewerAltitude in [100.0, 119, 125] {
            let result = VerticalPresentationPolicy.placement(
                vertical: vertical, offset: 0.005, cameraWorldY: 4,
                cameraEllipsoidalAltitude: viewerAltitude, cameraVerticalAccuracy: 1,
                cameraMeasuredAt: now, now: now)
            XCTAssertFalse(result.isProvisional)
            XCTAssertEqual(Double(result.worldY) - 4 + viewerAltitude, 120.005, accuracy: 0.00001)
        }
    }

    func testUnknownTerrainAndRoofStayProvisionalWithoutInventedBuildingHeight() {
        for reference in [VerticalPlacement.Reference.terrain, VerticalPlacement.Reference.rooftop] {
            let result = VerticalPresentationPolicy.placement(
                vertical: VerticalPlacement(reference: reference), offset: 2, cameraWorldY: 4,
                cameraEllipsoidalAltitude: 100, cameraVerticalAccuracy: 1,
                cameraMeasuredAt: now, now: now)
            XCTAssertTrue(result.isProvisional)
            XCTAssertEqual(result.worldY, 6)
        }
    }

    func testWrongDatumOldFixAndPoorAccuracyDoNotEarnResolvedHeight() throws {
        let vertical = try XCTUnwrap(VerticalPresentationPolicy.publishableSupport(
            altitudeWGS84: 120, uncertainty: 1, measuredAt: now, now: now))
        var wrongDatum = vertical
        wrongDatum.verticalDatum = "meanSeaLevel"
        for (metadata, accuracy, age) in [(wrongDatum, 1.0, 0.0), (vertical, 4.0, 0.0),
                                         (vertical, 1.0, 6.0), (vertical, 1.0, -1.0)] {
            let result = VerticalPresentationPolicy.placement(
                vertical: metadata, offset: 0, cameraWorldY: 4,
                cameraEllipsoidalAltitude: 100, cameraVerticalAccuracy: accuracy,
                cameraMeasuredAt: now.addingTimeInterval(-age), now: now)
            XCTAssertTrue(result.isProvisional)
            XCTAssertEqual(result.worldY, 4)
        }
    }

    func testPublicationRequiresFreshFiniteGeographicAltitudeAndVerticalEvidence() {
        for (altitude, accuracy, age) in [(Double.nan, 1.0, 0.0), (100.0, 0.0, 0.0),
                                          (100.0, 2.1, 0.0), (100.0, 1.0, 2.0),
                                          (100.0, 1.0, -1.0)] {
            XCTAssertNil(VerticalPresentationPolicy.publishableSupport(
                altitudeWGS84: altitude, uncertainty: accuracy,
                measuredAt: now.addingTimeInterval(-age), now: now))
        }
    }

    func testClampedDamagedOffsetCannotBecomeResolvedSupport() throws {
        let vertical = try XCTUnwrap(VerticalPresentationPolicy.publishableSupport(
            altitudeWGS84: 120, uncertainty: 1, measuredAt: now, now: now))
        for (offset, bounded) in [(21.0, 20.0), (-3.0, -2.0),
                                  (Double.infinity, 0.0), (Double.nan, 0.0)] {
            let appearance = VerticalPresentationPolicy.placement(
                vertical: vertical, offset: offset, cameraWorldY: 4,
                cameraEllipsoidalAltitude: 100, cameraVerticalAccuracy: 1,
                cameraMeasuredAt: now, now: now)
            XCTAssertTrue(appearance.isProvisional)
            XCTAssertEqual(Double(appearance.worldY), 4 + bounded, accuracy: 0.0001)
        }
        for valid in [-2.0, 20.0] {
            let appearance = VerticalPresentationPolicy.placement(
                vertical: vertical, offset: valid, cameraWorldY: 4,
                cameraEllipsoidalAltitude: 100, cameraVerticalAccuracy: 1,
                cameraMeasuredAt: now, now: now)
            XCTAssertFalse(appearance.isProvisional)
        }
    }
}
