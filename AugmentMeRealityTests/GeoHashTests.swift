import CoreLocation
import XCTest

@testable import AugmentMeReality

/// ADR-039: the geo-query math must be right before any Firestore index
/// depends on it. Known vectors + self-consistency (no network needed).
final class GeoHashTests: XCTestCase {

    func testKnownVector() {
        // Canonical example (Wikipedia): 57.64911, 10.40744 → u4pruydqqvj
        XCTAssertEqual(
            GeoHash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11),
            "u4pruydqqvj"
        )
    }

    func testEncodeDecodeRoundTripWithinCell() {
        let cases: [(Double, Double)] = [
            (51.5074, -0.1278), (-33.8688, 151.2093), (0.0, 0.0), (37.7749, -122.4194),
        ]
        for (lat, lon) in cases {
            let hash = GeoHash.encode(latitude: lat, longitude: lon, precision: 9)
            let center = GeoHash.decode(hash)
            XCTAssertNotNil(center)
            // Precision 9 cells are ~4.8 m tall — the center must be within one cell.
            XCTAssertEqual(center!.latitude, lat, accuracy: 0.0001)
            XCTAssertEqual(center!.longitude, lon, accuracy: 0.0002)
        }
    }

    func testNeighborsAreDistinctAdjacentCells() {
        let hash = GeoHash.encode(latitude: 51.5074, longitude: -0.1278, precision: 7)
        let neighbors = GeoHash.neighbors(of: hash)
        XCTAssertEqual(neighbors.count, 8)
        XCTAssertEqual(Set(neighbors).count, 8, "neighbors must be distinct")
        XCTAssertFalse(neighbors.contains(hash), "cell is not its own neighbor")
        // Every neighbor's center decodes to within ~2 cell sizes of the original.
        let origin = GeoHash.decode(hash)!
        for neighbor in neighbors {
            let center = GeoHash.decode(neighbor)!
            XCTAssertEqual(center.latitude, origin.latitude, accuracy: 0.01)
            XCTAssertEqual(center.longitude, origin.longitude, accuracy: 0.01)
        }
    }

    func testQueryBoundsCoverPointsInsideRadius() {
        let center = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        let bounds = GeoHash.queryBounds(center: center, radiusMeters: 2_000)
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertLessThanOrEqual(bounds.count, 9)

        // Points inside the radius must land in some [start, end) range.
        let inside = [
            CLLocationCoordinate2D(latitude: 51.515, longitude: -0.12),
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.14),
        ]
        for point in inside {
            let hash = GeoHash.encode(
                latitude: point.latitude, longitude: point.longitude, precision: 9
            )
            let covered = bounds.contains { hash >= $0.start && hash < $0.end }
            XCTAssertTrue(covered, "point \(point) escaped the query bounds")
        }

        // A point far outside must NOT be covered.
        let paris = GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: 9)
        XCTAssertFalse(bounds.contains { paris >= $0.start && paris < $0.end })
    }
}
