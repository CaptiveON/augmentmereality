import XCTest
@testable import AugmentMeReality

final class DropOwnershipTests: XCTestCase {
    func testOwnedReceivedLegacyAndUnresolvedMatrix() {
        var drop = GeoDrop()
        drop.ownerUid = "owner"
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .owned)
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "other"), .unresolved)
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: nil), .unresolved)

        drop.receivedViaLink = true
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "other"), .received)
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .unresolved)

        drop.ownerUid = nil
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .received)
        drop.receivedViaLink = nil
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .legacyLocal)
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: nil), .legacyLocal)
    }

    func testMalformedIdentityNeverBecomesOwner() {
        var drop = GeoDrop()
        drop.ownerUid = " owner "
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .unresolved)
        drop.ownerUid = ""
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: "owner"), .unresolved)
        drop.ownerUid = "owner"
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: " owner "), .unresolved)
        XCTAssertEqual(DropOwnershipRole(drop: drop, currentUID: ""), .unresolved)
    }
}
