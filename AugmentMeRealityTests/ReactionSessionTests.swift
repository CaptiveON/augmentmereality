import XCTest
@testable import AugmentMeReality

/// Round 6 (counsel round-5 critical 1): the RITUAL never depends on network
/// I/O — the wrap (the only route to the Memory screen) starts on the tap;
/// the delivery pill carries the honesty; per-send tokens keep late
/// completions from repainting the wrong state.
@MainActor
final class ReactionSessionTests: XCTestCase {

    func testWrapStartsOnTapEvenWhenNoAckEverArrives() {
        let session = ReactionSession()
        session.startWatching(GeoDrop())

        _ = session.didReact("❤️")

        guard case .wrapping = session.phase else {
            XCTFail("the wrap must start on the tap — the Memory screen must never depend on a server ack")
            return
        }
        XCTAssertEqual(session.delivery, .sending, "honesty lives in the pill, not the lifecycle")
        session.endSession()
    }

    func testDeliveryOutcomesAreHonestAndDoNotRewindTheRitual() {
        let session = ReactionSession()
        session.startWatching(GeoDrop())

        let token = session.didReact("🎉")
        session.reactionQueued(token: token)
        XCTAssertEqual(session.delivery, .queued, "offline is 'queued', not a lie and not a failure")
        guard case .wrapping = session.phase else {
            XCTFail("a queued delivery must not rewind the session")
            return
        }

        session.reactionDelivered(token: token)
        XCTAssertEqual(session.delivery, .delivered)
        session.endSession()
    }

    func testStaleTokenCannotRepaintDelivery() {
        let session = ReactionSession()
        session.startWatching(GeoDrop())
        let staleToken = session.didReact("❤️")

        // The user moves on to a different drop — any in-flight send is stale.
        session.startWatching(GeoDrop())
        session.reactionDelivered(token: staleToken)
        XCTAssertNil(session.delivery, "a late ack for a previous drop must not repaint the new session")

        // And within one session, an older tap's failure must not overwrite a
        // newer tap's state.
        let first = session.didReact("❤️")
        let second = session.didReact("🎉")
        session.reactionFailed(token: first)
        XCTAssertEqual(session.delivery, .sending, "the older send's outcome is stale")
        session.reactionDelivered(token: second)
        XCTAssertEqual(session.delivery, .delivered)
        session.endSession()
    }
}
