import Foundation
import XCTest
@testable import AugmentMeReality

final class GeographicAnchorIntentTests: XCTestCase {
    func testAnchorIntentChangesOnlyWithAnchorDefiningFields() {
        let stored = GeoDrop(latitude: 51.5, longitude: -0.12,
                             heightAboveGround: 2, facingDegrees: 90,
                             anchorMode: "ground")
        let original = GeographicAnchorIntent(stored)

        var metadata = stored
        metadata.message = "new caption"
        metadata.colorHex = "#000000"
        metadata.ownerUid = "new-owner"
        XCTAssertEqual(GeographicAnchorIntent(metadata), original)

        var changed = stored
        changed.latitude += 0.00001
        XCTAssertNotEqual(GeographicAnchorIntent(changed), original)
        changed = stored
        changed.longitude -= 0.00001
        XCTAssertNotEqual(GeographicAnchorIntent(changed), original)
        changed = stored
        changed.heightAboveGround = 0.5
        XCTAssertNotEqual(GeographicAnchorIntent(changed), original)
        changed = stored
        changed.facingDegrees = 180
        XCTAssertNotEqual(GeographicAnchorIntent(changed), original)
    }

    func testLegacyAndExplicitTerrainRoofRoutes() {
        var legacy = GeoDrop(anchorMode: "ground")
        let ground = GeographicAnchorIntent(legacy)
        XCTAssertTrue(ground.allowsTerrainGeoAnchor)
        XCTAssertTrue(ground.allowsTerrainVPS)
        XCTAssertFalse(ground.allowsRooftopVPS)
        XCTAssertFalse(ground.requiresAbsoluteVPS)
        XCTAssertTrue(ground.canRequestVPSAnchor)

        legacy.anchorMode = "rooftop"
        let oldRoof = GeographicAnchorIntent(legacy)
        XCTAssertFalse(oldRoof.allowsTerrainGeoAnchor)
        XCTAssertTrue(oldRoof.allowsRooftopVPS)

        legacy.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.terrain
        )
        let explicitTerrain = GeographicAnchorIntent(legacy)
        XCTAssertTrue(explicitTerrain.allowsTerrainGeoAnchor,
                      "explicit terrain overrides an old rooftop mode")
        XCTAssertFalse(explicitTerrain.allowsRooftopVPS)
        legacy.anchorMode = "ground"
        legacy.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.rooftop
        )
        let explicitRoof = GeographicAnchorIntent(legacy)
        XCTAssertTrue(explicitRoof.allowsRooftopVPS,
                      "explicit roof overrides an old ground mode")
        XCTAssertFalse(explicitRoof.allowsTerrainGeoAnchor)
    }

    func testLocalSupportRequiresCompatibleAbsoluteAltitude() {
        var drop = GeoDrop(latitude: 51.5, longitude: -0.12,
                           heightAboveGround: 0.005, anchorMode: "ground")
        drop.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.localARRaycast
        )
        let provisional = GeographicAnchorIntent(drop)
        XCTAssertFalse(provisional.allowsTerrainGeoAnchor)
        XCTAssertFalse(provisional.allowsTerrainVPS)
        XCTAssertFalse(provisional.allowsRooftopVPS)
        XCTAssertFalse(provisional.requiresAbsoluteVPS)
        XCTAssertFalse(provisional.canRequestVPSAnchor)

        let resolved = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: 120,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: 1,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        drop.verticalPlacement = resolved
        let absolute = GeographicAnchorIntent(drop)
        XCTAssertNotEqual(absolute, provisional)
        XCTAssertTrue(absolute.requiresAbsoluteVPS)
        XCTAssertTrue(absolute.canRequestVPSAnchor)
        XCTAssertEqual(absolute.absoluteAltitudeMeters ?? 0, 120.005, accuracy: 0.0001)

        drop.verticalPlacement?.verticalDatum = "meanSeaLevel"
        let wrongDatum = GeographicAnchorIntent(drop)
        XCTAssertNotEqual(wrongDatum, absolute)
        XCTAssertFalse(wrongDatum.canRequestVPSAnchor)
        XCTAssertNil(wrongDatum.absoluteAltitudeMeters)
    }

    func testFutureReferenceInvalidatesLegacyAnchorWithoutReinterpretingIt() {
        var drop = GeoDrop(anchorMode: "ground")
        let old = GeographicAnchorIntent(drop)
        drop.verticalPlacement = VerticalPlacement(reference: "bridgeDeckV4")
        let future = GeographicAnchorIntent(drop)
        XCTAssertNotEqual(future, old)
        XCTAssertEqual(future.verticalReference, VerticalPlacement.Reference.unresolved)
        XCTAssertTrue(future.requiresVerticalResolutionBeforeAnchor)
        XCTAssertFalse(future.allowsTerrainGeoAnchor)
        XCTAssertFalse(future.canRequestVPSAnchor)

        drop.heightAboveGround = 3
        XCTAssertFalse(GeographicAnchorIntent(drop).canRequestVPSAnchor,
                       "an ordinary height edit does not convert a future support")
    }

    func testThirtyMetreVerticalUncertaintyCannotResolveLocalSupport() {
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
        var drop = GeoDrop(latitude: 51.5, longitude: -0.12,
                           heightAboveGround: 0.005)
        drop.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: 120,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: 30,
            measuredAt: measuredAt,
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        XCTAssertNil(drop.verticalPlacement?.usableResolvedSupportAltitudeMeters)
        XCTAssertFalse(GeographicAnchorIntent(drop).canRequestVPSAnchor)
        let appearance = VerticalPresentationPolicy.placement(
            vertical: drop.verticalPlacement, offset: drop.heightAboveGround,
            cameraWorldY: 4, cameraEllipsoidalAltitude: 100,
            cameraVerticalAccuracy: 1, cameraMeasuredAt: measuredAt,
            now: measuredAt
        )
        XCTAssertTrue(appearance.isProvisional)
    }

    func testUnboundedRawHeightCannotDefineAnyGeographicAnchor() {
        let support = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: 120,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: 1,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        for height in [Double.nan, .infinity, -2.1, 20.1, 1e100] {
            for reference in [VerticalPlacement.Reference.terrain,
                              VerticalPlacement.Reference.rooftop,
                              VerticalPlacement.Reference.localSupport] {
                var drop = GeoDrop(heightAboveGround: height, anchorMode: "ground")
                drop.verticalPlacement = reference == VerticalPlacement.Reference.localSupport
                    ? support : VerticalPlacement(reference: reference)
                let intent = GeographicAnchorIntent(drop)
                XCTAssertFalse(intent.canRequestVPSAnchor)
                XCTAssertFalse(intent.allowsTerrainGeoAnchor)
                XCTAssertNil(intent.absoluteAltitudeMeters)
                XCTAssertEqual(intent, GeographicAnchorIntent(drop),
                               "a damaged row must not invalidate its intent every tick")
            }
        }
    }
}
