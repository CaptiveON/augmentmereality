import CloudKit
import XCTest
@testable import AugmentMeReality

final class CloudKitDropCodecTests: XCTestCase {
    func testGeographicQualitySurvivesRecordRoundTrip() throws {
        var drop = GeoDrop(latitude: 51.5, longitude: -0.12)
        drop.geographicQuality = try JSONDecoder().decode(GeographicQuality.self, from: Data("""
        {"source":"vpsProjection","horizontalEstimateMeters":2.5,
         "sensorHorizontalAccuracyMeters":2.0,"cameraHorizontalAccuracyMeters":1.5,
         "yawAccuracyDegrees":3.0,"projectionDistanceMeters":10.0,
         "measuredAt":800000000}
        """.utf8))
        let record = CKRecord(recordType: "GeoDrop", recordID: .init(recordName: drop.id.uuidString))
        drop.populate(record)

        let restored = try XCTUnwrap(GeoDrop(record: record))
        XCTAssertNotNil(restored.geographicQuality)
        XCTAssertEqual(restored.geographicQuality, drop.geographicQuality)
        XCTAssertEqual(restored.coordinate.latitude, drop.coordinate.latitude)
        XCTAssertEqual(restored.coordinate.longitude, drop.coordinate.longitude)
    }

    func testClearingQualityRemovesPreviouslyStoredClaim() throws {
        var drop = GeoDrop()
        drop.geographicQuality = try JSONDecoder().decode(GeographicQuality.self,
            from: Data("{\"source\":\"mapSelection\"}".utf8))
        let record = CKRecord(recordType: "GeoDrop", recordID: .init(recordName: drop.id.uuidString))
        drop.populate(record)
        XCTAssertNotNil(record["geographicQuality"])

        drop.geographicQuality = nil
        drop.populate(record)
        XCTAssertNil(record["geographicQuality"])
        XCTAssertNil(try XCTUnwrap(GeoDrop(record: record)).geographicQuality)
    }

    func testLegacyAndMalformedQualityKeepReadableDrop() throws {
        let drop = GeoDrop(message: "Keep this content", latitude: 1, longitude: 2)
        let record = CKRecord(recordType: "GeoDrop", recordID: .init(recordName: drop.id.uuidString))
        drop.populate(record)
        XCTAssertNil(try XCTUnwrap(GeoDrop(record: record)).geographicQuality)

        record["geographicQuality"] = Data("not valid JSON".utf8)
        let restored = try XCTUnwrap(GeoDrop(record: record))
        XCTAssertEqual(restored.id, drop.id)
        XCTAssertEqual(restored.message, drop.message)
        XCTAssertNil(restored.geographicQuality)
    }
    func testVerticalReferenceAltitudeAndDatumSurviveRoundTripAndClear() throws {
        var drop = GeoDrop(heightAboveGround: 0.005, anchorMode: "rooftop")
        drop.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: 120.25,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: 1, measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        let record = CKRecord(recordType: "GeoDrop", recordID: .init(recordName: drop.id.uuidString))
        drop.populate(record)
        let restored = try XCTUnwrap(GeoDrop(record: record))
        XCTAssertEqual(restored.verticalPlacement, drop.verticalPlacement)
        XCTAssertEqual(restored.anchorMode, drop.anchorMode)
        XCTAssertEqual(restored.heightAboveGround, 0.005)

        drop.verticalPlacement = nil
        drop.populate(record)
        XCTAssertNil(record["verticalPlacement"])
        XCTAssertEqual(try XCTUnwrap(GeoDrop(record: record)).verticalReference,
                       VerticalPlacement.Reference.unresolved)
        record["verticalPlacement"] = Data("broken".utf8)
        let malformed = try XCTUnwrap(GeoDrop(record: record))
        XCTAssertEqual(malformed.id, drop.id)
        XCTAssertTrue(malformed.requiresVerticalResolutionBeforeAnchor)
        XCTAssertFalse(GeographicAnchorIntent(malformed).canRequestVPSAnchor)

        record["verticalPlacement"] = "broken"
        let wrongType = try XCTUnwrap(GeoDrop(record: record))
        XCTAssertTrue(wrongType.requiresVerticalResolutionBeforeAnchor)
        XCTAssertFalse(GeographicAnchorIntent(wrongType).canRequestVPSAnchor)
    }

}
