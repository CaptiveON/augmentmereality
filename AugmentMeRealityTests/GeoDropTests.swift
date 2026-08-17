import UIKit
import XCTest
@testable import AugmentMeReality

final class GeoDropTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let drop = GeoDrop(
            content: .text3D,
            message: "HAPPY BIRTHDAY! 🎂",
            latitude: 24.8607,
            longitude: 67.0011,
            heightAboveGround: 4.5,
            scale: 6,
            colorHex: "#32ADE6",
            createdBy: "Adnan"
        )
        let data = try JSONEncoder().encode(drop)
        let decoded = try JSONDecoder().decode(GeoDrop.self, from: data)
        XCTAssertEqual(decoded, drop)
    }

    func testUnknownContentDecodesAsPlaceholderNotThrow() throws {
        // Forward-compat policy v2 (ADR-045/046, supersedes the ADR-016 throw
        // policy): a future content type must decode to a safe placeholder —
        // a throw inside an array decode fails the WHOLE library and the
        // corrupt-quarantine then wipes it.
        var drop = GeoDrop()
        drop.message = "x"
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(drop)
        ) as! [String: Any]
        json["content"] = "hologram-dragon"
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(GeoDrop.self, from: data)
        XCTAssertEqual(decoded.content, .text3D)
        XCTAssertEqual(decoded.message, "x", "other fields survive")
    }

    func testColorHexParsing() {
        XCTAssertNotNil(UIColor(hex: "#FF4D6D"))
        XCTAssertNotNil(UIColor(hex: "34C759"), "leading # must be optional")
        XCTAssertNil(UIColor(hex: "#XYZ123"))
        XCTAssertNil(UIColor(hex: "#FFF"), "shorthand not supported → nil, not garbage")

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(hex: "#FF0000")?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, 1, accuracy: 0.001)
        XCTAssertEqual(green, 0, accuracy: 0.001)
    }

    func testInvalidHexFallsBackToVisibleColor() {
        var drop = GeoDrop()
        drop.colorHex = "garbage"
        // uiColor must never be nil/clear — content must stay visible in the field.
        XCTAssertNotNil(drop.uiColor.cgColor.alpha)
        XCTAssertEqual(drop.uiColor, .systemPink)
    }

    func testTitleFallbackAndTruncation() {
        var drop = GeoDrop()
        drop.content = .balloons
        drop.message = "   "
        XCTAssertEqual(drop.title, "Balloons", "blank message falls back to type name")

        drop.message = String(repeating: "A", count: 60)
        XCTAssertTrue(drop.title.count <= 25)
        XCTAssertTrue(drop.title.hasSuffix("…"))
    }
}
