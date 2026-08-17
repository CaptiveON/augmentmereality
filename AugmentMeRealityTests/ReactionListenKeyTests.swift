import XCTest

@testable import AugmentMeReality

/// Wave B, counsel PBS-3: the sender-side reaction subscription is keyed on the
/// IDENTITY of the watched drop set. The pre-fix key was the drop COUNT, which
/// missed the in-place share mutation — the sender was never listening on the
/// drop they just shared, so the loop's payoff toast never arrived.
final class ReactionListenKeyTests: XCTestCase {

    private func drop(shared: Bool = false, received: Bool = false, owner: String? = nil) -> GeoDrop {
        var drop = GeoDrop()
        drop.visibility = shared ? "link" : "private"
        drop.receivedViaLink = received ? true : nil
        drop.ownerUid = owner
        return drop
    }

    func testSharingADropChangesTheKeyWithoutChangingTheCount() {
        var drops = [drop(), drop(), drop()]
        let before = ReactionService.listenKey(for: drops, myUid: "me")

        // The exact PBS-3 scenario: share mutates one drop IN PLACE.
        drops[1].visibility = "link"
        let after = ReactionService.listenKey(for: drops, myUid: "me")

        XCTAssertEqual(drops.count, 3, "sharing must not change the count (that was the bug)")
        XCTAssertNotEqual(before, after, "the key must restart the listener on share")
    }

    func testKeyIsOrderIndependent() {
        let a = drop(shared: true), b = drop(shared: true)
        XCTAssertEqual(
            ReactionService.listenKey(for: [a, b], myUid: "me"),
            ReactionService.listenKey(for: [b, a], myUid: "me"),
            "reordering the library must not churn the subscription"
        )
    }

    func testKeyChangesWhenUidArrives() {
        let drops = [drop(shared: true)]
        XCTAssertNotEqual(
            ReactionService.listenKey(for: drops, myUid: nil),
            ReactionService.listenKey(for: drops, myUid: "me"),
            "sign-in completing must re-establish the listener"
        )
    }

    func testWatchedDropsExcludeForeignAndReceived() {
        let mine = drop(shared: true, owner: "me")
        let legacyNoOwner = drop(shared: true)
        let received = drop(shared: true, received: true)
        let foreign = drop(shared: true, owner: "someone-else")
        let unshared = drop()

        let watched = ReactionService.watchedDrops(
            in: [mine, legacyNoOwner, received, foreign, unshared], myUid: "me"
        )
        XCTAssertEqual(Set(watched.map(\.id)), Set([mine.id, legacyNoOwner.id]))
    }

    func testWatchedDropsCapAtTenNewestFirst() {
        // Library order is newest-first (ADR-045 P0 #2 fixed suffix→prefix);
        // the cap must keep the FIRST ten — the just-shared drop is index 0.
        let drops = (0..<12).map { _ in drop(shared: true, owner: "me") }
        let watched = ReactionService.watchedDrops(in: drops, myUid: "me")
        XCTAssertEqual(watched.count, 10)
        XCTAssertEqual(watched.first?.id, drops.first?.id, "the newest share must be watched")
    }
}
