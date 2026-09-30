import Foundation
import XCTest

@testable import AugmentMeReality

/// AUDIT P0 regression pin: decoding data written by OLDER app versions must
/// never throw — a throw feeds the corrupt-quarantine and silently empties the
/// user's library on update. Every future field addition must keep this green.
final class GeoDropCompatibilityTests: XCTestCase {

    /// Genuine pre-Wave-6.2 shape: no visibility/anchorMode/ownerUid/recipient.
    func testDecodesPreSharingEraJSON() throws {
        let legacy = """
        [{
          "id": "E0B39736-9A7A-4BC3-AFD1-E2C34F722E7B",
          "content": "text3D",
          "message": "HAPPY BIRTHDAY!",
          "latitude": 51.5,
          "longitude": -0.12,
          "heightAboveGround": 3,
          "scale": 3,
          "colorHex": "#FF4D6D",
          "createdBy": "Adnan",
          "createdAt": 741650000
        }]
        """
        let drops = try JSONDecoder().decode([GeoDrop].self, from: Data(legacy.utf8))
        XCTAssertEqual(drops.count, 1)
        let drop = try XCTUnwrap(drops.first)
        XCTAssertEqual(drop.message, "HAPPY BIRTHDAY!")
        XCTAssertEqual(drop.visibility, "private", "new fields default, never throw")
        XCTAssertEqual(drop.anchorMode, "ground")
        XCTAssertNil(drop.verticalPlacement)
        XCTAssertEqual(drop.verticalReference, VerticalPlacement.Reference.unresolved)
        XCTAssertFalse(drop.requiresVerticalResolutionBeforeAnchor)
        XCTAssertEqual(drop.preferredAnchorMode, "ground")
        XCTAssertNil(drop.ownerUid)
        XCTAssertNil(drop.receivedViaLink)
    }

    /// A FUTURE content type (newer client) must not fail the library decode.
    func testUnknownContentTypeDecodesToPlaceholder() throws {
        let future = #"[{"content": "hologram_v9", "latitude": 1.0, "longitude": 2.0}]"#
        let drops = try JSONDecoder().decode([GeoDrop].self, from: Data(future.utf8))
        XCTAssertEqual(drops.first?.content, .text3D)
    }

    /// Even a minimal skeleton (fields from the very first wave) survives.
    func testDecodesMinimalSkeleton() throws {
        let minimal = #"[{"latitude": 1.0, "longitude": 2.0}]"#
        let drops = try JSONDecoder().decode([GeoDrop].self, from: Data(minimal.utf8))
        XCTAssertEqual(drops.first?.content, .text3D)
        XCTAssertEqual(drops.first?.scale ?? 0, 1, accuracy: 0.001)
    }

    /// Round-trip of the CURRENT shape stays lossless.
    func testCurrentShapeRoundTrip() throws {
        var drop = GeoDrop(
            content: .animated, message: "hi", latitude: 3, longitude: 4,
            heightAboveGround: 1, scale: 2, colorHex: "#FFC857", createdBy: "x",
            anchorMode: "rooftop"
        )
        drop.assetName = "toy_drummer"
        drop.visibility = "link"
        drop.recipientName = "Sara"
        drop.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.rooftop,
            resolvedSupportAltitudeMeters: 38.4,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: 0.8,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        let data = try JSONEncoder().encode([drop])
        let back = try JSONDecoder().decode([GeoDrop].self, from: data).first
        XCTAssertEqual(back, drop)
    }

    func testMalformedAndFutureVerticalMetadataDoNotLoseTheDrop() throws {
        let malformed = #"{"message":"survives","anchorMode":"rooftop","verticalPlacement":17}"#
        let drop = try JSONDecoder().decode(GeoDrop.self, from: Data(malformed.utf8))
        XCTAssertEqual(drop.message, "survives")
        XCTAssertEqual(drop.verticalReference, VerticalPlacement.Reference.unresolved)
        XCTAssertNotNil(drop.verticalPlacement,
                        "a present malformed value must differ from absent legacy metadata")
        XCTAssertTrue(drop.requiresVerticalResolutionBeforeAnchor)
        XCTAssertFalse(GeographicAnchorIntent(drop).canRequestVPSAnchor)
        XCTAssertEqual(drop.preferredAnchorMode, "rooftop",
                       "the old mode remains readable but cannot resolve this support")

        let future = #"{"verticalPlacement":{"reference":"bridgeDeckV4","verticalDatum":"futureDatum","resolvedSupportAltitudeMeters":20,"verticalUncertaintyMeters":0.1,"measuredAt":1700000000,"provenance":"futureSensor"}}"#
        let futureDrop = try JSONDecoder().decode(GeoDrop.self, from: Data(future.utf8))
        XCTAssertEqual(futureDrop.verticalPlacement?.reference, "bridgeDeckV4")
        XCTAssertEqual(futureDrop.verticalReference, VerticalPlacement.Reference.unresolved)
        XCTAssertTrue(futureDrop.requiresVerticalResolutionBeforeAnchor)
        XCTAssertNil(futureDrop.verticalPlacement?.usableResolvedSupportAltitudeMeters)
    }

    func testNullVerticalMetadataKeepsLegacyAnchorRoute() throws {
        let json = #"{"anchorMode":"ground","verticalPlacement":null}"#
        let drop = try JSONDecoder().decode(GeoDrop.self, from: Data(json.utf8))
        XCTAssertNil(drop.verticalPlacement)
        XCTAssertFalse(drop.requiresVerticalResolutionBeforeAnchor)
        XCTAssertTrue(GeographicAnchorIntent(drop).allowsTerrainGeoAnchor)
    }

    func testExtremeStoredHeightKeepsRawValueButBoundsPresentation() throws {
        var drop = GeoDrop(heightAboveGround: 1e100)
        XCTAssertEqual(drop.presentationHeightAboveGround, 20)
        let restored = try JSONDecoder().decode(GeoDrop.self, from: JSONEncoder().encode(drop))
        XCTAssertEqual(restored.heightAboveGround, 1e100)
        XCTAssertEqual(restored.presentationHeightAboveGround, 20)

        drop.heightAboveGround = -8
        XCTAssertEqual(drop.presentationHeightAboveGround, -2)
        drop.heightAboveGround = .nan
        XCTAssertEqual(drop.presentationHeightAboveGround, 0)
    }

    func testVerticalDatumAndReferencePrecedence() throws {
        var drop = GeoDrop(anchorMode: "ground")
        drop.verticalPlacement = VerticalPlacement(reference: VerticalPlacement.Reference.rooftop)
        XCTAssertEqual(drop.preferredAnchorMode, "rooftop")
        drop.anchorMode = "rooftop"
        drop.verticalPlacement = VerticalPlacement(reference: VerticalPlacement.Reference.terrain)
        XCTAssertEqual(drop.preferredAnchorMode, "ground")

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var placement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: 21.5,
            verticalDatum: "egm96Geoid",
            verticalUncertaintyMeters: 1,
            measuredAt: date,
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
        XCTAssertNil(placement.usableResolvedSupportAltitudeMeters)
        placement.verticalDatum = VerticalPlacement.Datum.wgs84Ellipsoid
        XCTAssertEqual(placement.usableResolvedSupportAltitudeMeters, 21.5)
        placement.provenance = VerticalPlacement.Provenance.localARRaycast
        XCTAssertNil(placement.usableResolvedSupportAltitudeMeters,
                     "AR world Y is not a geographic altitude")
        placement.provenance = VerticalPlacement.Provenance.vpsProjection
        placement.measuredAt = nil
        XCTAssertNil(placement.usableResolvedSupportAltitudeMeters)
        placement.measuredAt = date
        placement.resolvedSupportAltitudeMeters = nil
        XCTAssertNil(placement.usableResolvedSupportAltitudeMeters)
        placement.resolvedSupportAltitudeMeters = .infinity
        XCTAssertNil(placement.usableResolvedSupportAltitudeMeters)
    }

    func testDamagedOptionalVerticalFieldsRemainUnresolved() throws {
        let json = #"{"message":"kept","verticalPlacement":{"reference":42,"resolvedSupportAltitudeMeters":"high","verticalDatum":9,"verticalUncertaintyMeters":-1,"measuredAt":"bad"}}"#
        let drop = try JSONDecoder().decode(GeoDrop.self, from: Data(json.utf8))
        XCTAssertEqual(drop.message, "kept")
        XCTAssertEqual(drop.verticalReference, VerticalPlacement.Reference.unresolved)
        XCTAssertTrue(drop.requiresVerticalResolutionBeforeAnchor)
        XCTAssertNil(drop.verticalPlacement?.usableResolvedSupportAltitudeMeters)
        XCTAssertNil(drop.verticalPlacement?.verticalUncertaintyMeters)
    }
}
