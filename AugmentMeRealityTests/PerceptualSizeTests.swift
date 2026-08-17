import XCTest
@testable import AugmentMeReality

/// ADR-049: the perceptual size-compensation law. These are the invariants that
/// separate "compensation" from the two banned failure modes (constant apparent
/// size, billboard stickers) — if any of them breaks, distance perception breaks.
final class PerceptualSizeTests: XCTestCase {

    /// Inside d₀ (and for any degenerate distance) the law is exactly identity:
    /// near-field content, room/Playground drops, and the reveal walk-up render
    /// pure true-scale.
    func testIdentityNearAndDegenerate() {
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: 0.5), 1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: AppConfig.perceptualD0), 1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: 0), 1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: -3), 1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: .nan), 1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: .infinity), 1)
    }

    /// The factor itself grows monotonically and never exceeds the cap —
    /// multi-km drops stay sane (a scale-3 text at 2 km renders ≈12–21 m tall,
    /// about a building, not a mountain).
    func testMonotonicAndCapped() {
        var previous: Float = 0
        for distance in stride(from: Float(1), through: 5_000, by: 7) {
            let factor = GeoARSessionManager.perceptualFactor(atDistance: distance)
            XCTAssertGreaterThanOrEqual(factor, previous, "factor regressed at \(distance) m")
            XCTAssertGreaterThanOrEqual(factor, 1)
            XCTAssertLessThanOrEqual(factor, AppConfig.perceptualCap)
            previous = factor
        }
        XCTAssertEqual(
            GeoARSessionManager.perceptualFactor(atDistance: 1_000_000),
            AppConfig.perceptualCap
        )
    }

    /// ADR-049 worked values — the numbers the decision was made on. If tuning
    /// moves d₀/β/cap, this test failing is the prompt to re-run FT-33 and
    /// update the ADR, not to delete the assertion.
    func testWorkedValuesMatchADR() {
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: 50), 1.9, accuracy: 0.1)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: 200), 3.1, accuracy: 0.2)
        XCTAssertEqual(GeoARSessionManager.perceptualFactor(atDistance: 2_000), 6.9, accuracy: 0.4)
    }

    /// THE invariant: apparent angular size θ(d) = 2·atan(h·C(d) / 2d) must be
    /// strictly decreasing — farther always looks smaller, approaching always
    /// grows. This is what β < 1 guarantees and what constant-apparent-size
    /// (the old sticker failure) violates.
    func testApparentAngleStillShrinksWithDistance() {
        let height: Float = 1.8 // scale-3 birthday text
        var previousAngle = Float.greatestFiniteMagnitude
        for distance in stride(from: Float(1), through: 5_000, by: 3) {
            let factor = GeoARSessionManager.perceptualFactor(atDistance: distance)
            let angle = 2 * atan(height * factor / (2 * distance))
            XCTAssertLessThan(
                angle, previousAngle,
                "apparent size failed to shrink between \(distance - 3) and \(distance) m"
            )
            previousAngle = angle
        }
    }

    /// Sanity on the tuning itself: β stays in the size-constancy band the ADR
    /// derived (0 < β < 1 keeps perspective dominant; β ≥ 1 would freeze or
    /// invert apparent size and re-create the sticker).
    func testTuningStaysInSafeBand() {
        XCTAssertGreaterThan(AppConfig.perceptualBeta, 0)
        XCTAssertLessThan(AppConfig.perceptualBeta, 1)
        XCTAssertGreaterThan(AppConfig.perceptualD0, 0)
        XCTAssertGreaterThanOrEqual(AppConfig.perceptualCap, 1)
    }
}
