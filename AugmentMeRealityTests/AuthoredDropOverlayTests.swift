import XCTest
@testable import AugmentMeReality

final class AuthoredDropOverlayTests: XCTestCase {
    func testCommittedPoseFeedsRepinUntilLibraryPublishesIt() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop()
        var authored = stored
        authored.heightAboveGround = 0.75
        authored.facingDegrees = 90
        overlay.stage(authored)

        var fresherMetadata = stored
        fresherMetadata.message = "Fresh server caption"
        fresherMetadata.ownerUid = "server-owner"
        let repin = overlay.resolve(fresherMetadata)
        XCTAssertEqual(repin.heightAboveGround, 0.75)
        XCTAssertEqual(repin.facingDegrees, 90)
        XCTAssertEqual(repin.message, "Fresh server caption")
        XCTAssertEqual(repin.ownerUid, "server-owner")

        var published = authored
        published.message = "Fresh server caption"
        published.ownerUid = "server-owner"
        XCTAssertEqual(overlay.resolve(published), published)
        var laterRemote = authored
        laterRemote.heightAboveGround = 1.25
        XCTAssertEqual(overlay.resolve(laterRemote), laterRemote,
                       "Published local state retires the temporary override")
    }

    func testNewerEditWinsWhileOlderAsyncPublicationArrives() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop()
        var first = stored
        first.heightAboveGround = 1
        var second = first
        second.heightAboveGround = 3
        overlay.stage(first)
        overlay.stage(second)

        XCTAssertEqual(overlay.resolve(first), second)
        XCTAssertEqual(overlay.resolve(stored), second)
        XCTAssertEqual(overlay.resolve(second), second)
    }

    func testRemovedDropDoesNotRetainUnpublishedEdit() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop()
        var authored = stored
        authored.heightAboveGround = 5
        overlay.stage(authored)
        overlay.retainOnly([])
        XCTAssertEqual(overlay.resolve(stored), stored)
    }

    func testPendingEditsAreBoundedToRecentVisibleDrops() {
        var overlay = AuthoredDropOverlay()
        var drops: [GeoDrop] = []
        for index in 0..<129 {
            let stored = GeoDrop()
            var authored = stored
            authored.heightAboveGround = Double(index + 10)
            overlay.stage(authored)
            drops.append(stored)
        }
        XCTAssertEqual(overlay.resolve(drops[0]), drops[0])
        XCTAssertEqual(overlay.resolve(drops[128]).heightAboveGround, 138)
    }

    func testPendingGeographicQualityStaysWithTheAuthoredCoordinate() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop(latitude: 51.5, longitude: -0.12)
        var authored = stored
        authored.latitude = 51.50001
        authored.geographicQuality = GeographicQuality(
            source: GeographicQuality.Source.vpsProjection,
            sensorHorizontalAccuracyMeters: 0.7,
            cameraHorizontalAccuracyMeters: 0.8,
            yawAccuracyDegrees: 2,
            projectionDistanceMeters: 4,
            measuredAt: Date()
        )
        overlay.stage(authored)

        var refreshed = stored
        refreshed.message = "new metadata"
        let duringSave = overlay.resolve(refreshed)
        XCTAssertEqual(duringSave.latitude, authored.latitude)
        XCTAssertEqual(duringSave.geographicQuality, authored.geographicQuality)
        XCTAssertEqual(duringSave.message, "new metadata")
        XCTAssertEqual(overlay.resolve(authored), authored)
    }

    func testFailedGeographicSaveRetiresOnlyItsOwnPendingPlacement() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop(latitude: 51.5, longitude: -0.12)
        var failed = stored
        failed.latitude += 0.00001
        failed.geographicQuality = GeographicQuality(
            source: GeographicQuality.Source.vpsProjection,
            sensorHorizontalAccuracyMeters: 0.7,
            cameraHorizontalAccuracyMeters: 0.8,
            yawAccuracyDegrees: 2,
            projectionDistanceMeters: 4,
            measuredAt: Date()
        )
        overlay.stage(failed)
        overlay.discardIfMatching(failed)
        XCTAssertEqual(overlay.resolve(stored), stored,
                       "A failed disk write must not advertise its VPS coordinate on refresh")

        var newer = failed
        newer.longitude -= 0.00001
        overlay.stage(failed)
        overlay.stage(newer)
        overlay.discardIfMatching(failed)
        XCTAssertEqual(overlay.resolve(stored), newer,
                       "A late failure cannot erase a newer authored placement")
    }

    func testVerticalMetadataMovesWithPendingAuthoredPlacement() {
        var overlay = AuthoredDropOverlay()
        let stored = GeoDrop(latitude: 51.5, longitude: -0.12)
        var authored = stored
        authored.heightAboveGround = 0.005
        authored.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: VerticalPlacement.Provenance.localARRaycast
        )
        overlay.stage(authored)
        var publishedMetadata = stored
        publishedMetadata.message = "edited elsewhere"
        let resolved = overlay.resolve(publishedMetadata)
        XCTAssertEqual(resolved.heightAboveGround, authored.heightAboveGround)
        XCTAssertEqual(resolved.verticalPlacement, authored.verticalPlacement)
        XCTAssertEqual(resolved.message, "edited elsewhere")
        XCTAssertEqual(overlay.resolve(authored), authored)
    }
}
