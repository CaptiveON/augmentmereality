import Foundation
import XCTest
import simd
@testable import AugmentMeReality

final class GeographicWritebackPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNearVPSProjectionCanPublishButSameYawAtDistanceCannot() throws {
        let near = try XCTUnwrap(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 0.8, cameraHorizontal: 1,
            yawDegrees: 5, distanceMeters: 10,
            measuredAt: now, now: now
        ))
        XCTAssertEqual(near.horizontalEstimateMeters ?? 0, 1.87, accuracy: 0.02)
        XCTAssertTrue(GeographicWritebackPolicy.mayPublish(near, at: now))

        let far = try XCTUnwrap(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 0.8, cameraHorizontal: 1,
            yawDegrees: 5, distanceMeters: 100,
            measuredAt: now, now: now
        ))
        XCTAssertGreaterThan(far.horizontalEstimateMeters ?? 0, 9)
        XCTAssertFalse(GeographicWritebackPolicy.mayPublish(far, at: now))
        XCTAssertGreaterThan(
            GeographicWritebackPolicy.viewingEstimate(
                savedHorizontal: 1, cameraHorizontal: 10,
                yawDegrees: 8, distanceMeters: 100
            ) ?? 0, 24,
            "a green 10 m / 8° localization gate cannot imply a precise shared point"
        )
    }

    func testTargetTransformAccuracyIsNotAddedTwice() throws {
        let quality = try XCTUnwrap(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 4, cameraHorizontal: 1,
            yawDegrees: 0, distanceMeters: 50,
            measuredAt: now, now: now
        ))
        XCTAssertEqual(quality.horizontalEstimateMeters, 4)
        XCTAssertFalse(GeographicWritebackPolicy.mayPublish(quality, at: now))
    }

    func testStaleInvalidAndForgedQualityCannotPublish() throws {
        XCTAssertNil(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 1, cameraHorizontal: 1,
            yawDegrees: 1, distanceMeters: 2,
            measuredAt: now.addingTimeInterval(-2), now: now
        ))
        XCTAssertNil(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: -.infinity, cameraHorizontal: 1,
            yawDegrees: 1, distanceMeters: 2,
            measuredAt: now, now: now
        ))
        XCTAssertNil(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 1, cameraHorizontal: 1,
            yawDegrees: 46, distanceMeters: 2,
            measuredAt: now, now: now
        ))

        var valid = try XCTUnwrap(GeographicWritebackPolicy.assessVPS(
            targetHorizontal: 0.8, cameraHorizontal: 1,
            yawDegrees: 1, distanceMeters: 5,
            measuredAt: now, now: now
        ))
        valid.horizontalEstimateMeters = 0.01
        XCTAssertFalse(GeographicWritebackPolicy.mayPublish(valid, at: now))
        valid.cameraHorizontalAccuracyMeters = .nan
        XCTAssertFalse(GeographicWritebackPolicy.mayPublish(valid, at: now))
    }

    func testMapAndLegacyCoordinatesNeverGainNumericPrecision() throws {
        let manual = GeographicQuality(
            source: GeographicQuality.Source.mapSelection,
            horizontalEstimateMeters: 0.01
        )
        XCTAssertNil(manual.horizontalEstimateMeters)
        XCTAssertFalse(GeographicWritebackPolicy.mayPublish(manual, at: now))

        let legacy = try JSONDecoder().decode(GeoDrop.self, from:
            Data(#"{"latitude":51.5,"longitude":-0.12}"#.utf8))
        XCTAssertNil(legacy.geographicQuality)
        let malformed = try JSONDecoder().decode(GeoDrop.self, from:
            Data(#"{"message":"survives","geographicQuality":{"source":17}}"#.utf8))
        XCTAssertEqual(malformed.message, "survives")
        XCTAssertNil(malformed.geographicQuality)
    }

    func testFutureSourceSurvivesRoundTripWithoutAQualityClaim() throws {
        var drop = GeoDrop()
        drop.geographicQuality = GeographicQuality(
            source: "surveyV3", horizontalEstimateMeters: 0.01
        )
        let decoded = try JSONDecoder().decode(GeoDrop.self, from: JSONEncoder().encode(drop))
        XCTAssertEqual(decoded.geographicQuality?.source, "surveyV3")
        XCTAssertNil(decoded.geographicQuality?.horizontalEstimateMeters)
    }

    func testMissingOrDamagedCaptureTimeKeepsDropButRemovesNumericClaim() throws {
        let vps = #"{"message":"survives","geographicQuality":{"source":"vpsProjection","sensorHorizontalAccuracyMeters":0.7,"cameraHorizontalAccuracyMeters":0.8,"yawAccuracyDegrees":2,"projectionDistanceMeters":4,"horizontalEstimateMeters":0.01}}"#
        let missingTime = try JSONDecoder().decode(GeoDrop.self, from: Data(vps.utf8))
        XCTAssertEqual(missingTime.message, "survives")
        XCTAssertEqual(missingTime.geographicQuality?.source, GeographicQuality.Source.vpsProjection)
        XCTAssertNil(missingTime.geographicQuality?.horizontalEstimateMeters)

        let damagedTime = vps.replacingOccurrences(
            of: #""horizontalEstimateMeters":0.01"#,
            with: #""horizontalEstimateMeters":0.01,"measuredAt":"invalid""#
        )
        let damaged = try JSONDecoder().decode(GeoDrop.self, from: Data(damagedTime.utf8))
        XCTAssertEqual(damaged.message, "survives")
        XCTAssertNil(damaged.geographicQuality?.horizontalEstimateMeters)

        let undatedFix = GeographicQuality(
            source: GeographicQuality.Source.deviceFix,
            sensorHorizontalAccuracyMeters: 3
        )
        XCTAssertNil(undatedFix.horizontalEstimateMeters)
        let historicalFix = GeographicQuality(
            source: GeographicQuality.Source.deviceFix,
            sensorHorizontalAccuracyMeters: 3,
            measuredAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertEqual(historicalFix.horizontalEstimateMeters, 3,
                       "Capture age does not erase the saved coordinate's historical estimate")
    }
}

final class LocalPinOverridesTests: XCTestCase {
    func testUnpublishedPinKeepsItsWorldPoseAcrossRefreshAndReAdmission() {
        var override = LocalPinOverrides()
        let stored = GeoDrop(message: "old", latitude: 51.5, longitude: -0.12)
        var local = stored
        local.heightAboveGround = 0.4
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(2, 0.4, -3, 1)
        override.stage(local, worldTransform: world)

        var refreshed = stored
        refreshed.message = "new from cloud"
        refreshed.ownerUid = "current-owner"
        let admitted = override.resolve(refreshed)
        XCTAssertEqual(admitted.heightAboveGround, 0.4)
        XCTAssertEqual(admitted.message, "new from cloud")
        XCTAssertEqual(admitted.ownerUid, "current-owner")
        XCTAssertEqual(override.worldTransform(for: stored.id)?.columns.3.x, 2)
        XCTAssertEqual(override.worldTransform(for: stored.id)?.columns.3.z, -3)
        XCTAssertEqual(admitted.latitude, stored.latitude,
                       "local-only pin must not rewrite the shared coordinate")

        local.scale = 2
        world.columns.3.y = 1
        override.update(local, worldTransform: world)
        XCTAssertEqual(override.resolve(refreshed).scale, 2)
        XCTAssertEqual(override.worldTransform(for: stored.id)?.columns.3.y, 1)
        override.remove(stored.id)
        XCTAssertEqual(override.resolve(refreshed), refreshed)
        XCTAssertNil(override.worldTransform(for: stored.id))
    }

    func testWorldFrameResetOrTransitRetiresEveryLocalPose() {
        var override = LocalPinOverrides()
        let drop = GeoDrop()
        override.stage(drop, worldTransform: matrix_identity_float4x4)
        XCTAssertTrue(override.contains(drop.id))
        override.reset()
        XCTAssertFalse(override.contains(drop.id))
        XCTAssertTrue(override.ids.isEmpty)
    }
}
