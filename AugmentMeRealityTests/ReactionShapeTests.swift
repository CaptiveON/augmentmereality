import XCTest
@testable import AugmentMeReality

/// Round 14 (counsel own-2 + seams-4): the rules' `hasOnly` key list and the
/// emulator suite both depend on the EXACT shape DropReaction encodes. The
/// Node drift lock parses the Swift source; this test locks the ENCODER's
/// output on-device — a property wrapper, a CodingKeys rename, or a new field
/// changes the wire shape without changing the parsed source, and the first
/// post-v3-deploy reaction under a drifted shape is permission-denied →
/// terminal verdict → the loop's payoff dies silently.
final class ReactionShapeTests: XCTestCase {
    func testDropReactionEncodedShapeMatchesTheRulesKeyList() throws {
        let reaction = DropReaction(emoji: "❤️", uid: "uid", byName: "name")
        let data = try JSONEncoder().encode(reaction)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            ["id", "emoji", "uid", "byName", "at"],
            "firestore.rules hasOnly + web/rules-tests must change in the same commit as this shape"
        )
    }
}
