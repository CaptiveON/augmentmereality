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
        let data = try JSONEncoder().encode([drop])
        let back = try JSONDecoder().decode([GeoDrop].self, from: data).first
        XCTAssertEqual(back, drop)
    }
}
