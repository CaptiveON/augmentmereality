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
}
