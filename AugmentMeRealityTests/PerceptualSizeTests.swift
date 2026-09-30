import RealityKit
import XCTest
@testable import AugmentMeReality

/// Physical content has one authored world size. The separately scaled waypoint
/// marker remains free to help the viewer find a distant drop.
final class PhysicalSizeTests: XCTestCase {
    func testWalkingAcrossFormerCompensationThresholdKeepsWorldBoundsAndProjection() async {
        await MainActor.run {
            let holder = Entity()
            let content = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(1, 2, 0.5)),
                materials: [UnlitMaterial(color: .white)]
            )
            let marker = Entity()
            let disc = Entity()
            holder.addChild(content)
            holder.addChild(marker)
            holder.addChild(disc)
            GeoARSessionManager.applyPhysicalSize(
                1.75, to: content, in: holder, marker: marker, disc: disc
            )
            let physical = content.visualBounds(relativeTo: holder).extents
            let footprint = disc.scale
            var projectedHeights: [Float] = []
            for distance in [Float(5), 7.9, 8, 8.1, 25, 60, 25, 5] {
                holder.position = [0, 0, -distance]
                let bounds = content.visualBounds(relativeTo: holder).extents
                XCTAssertEqual(bounds.x, physical.x, accuracy: 0.0001)
                XCTAssertEqual(bounds.y, physical.y, accuracy: 0.0001)
                XCTAssertEqual(bounds.z, physical.z, accuracy: 0.0001)
                XCTAssertEqual(disc.scale.x, footprint.x, accuracy: 0.0001)
                // Pinhole projection using the active camera's focal length
                // would apply this same 1/d relationship to the fixed bounds.
                projectedHeights.append(1_400 * bounds.y / distance)
            }
            XCTAssertEqual(projectedHeights.first!, projectedHeights.last!, accuracy: 0.0001)
            XCTAssertGreaterThan(projectedHeights[0], projectedHeights[5])
            XCTAssertEqual(projectedHeights[0] / projectedHeights[5], 12, accuracy: 0.0001)

            marker.scale = SIMD3<Float>(repeating: 8)
            XCTAssertEqual(content.visualBounds(relativeTo: holder).extents.y,
                           physical.y, accuracy: 0.0001)
            XCTAssertEqual(disc.scale.x, footprint.x, accuracy: 0.0001)
        }
    }

    func testScaleEditThenAssetReplacementAppliesAuthoredScaleOnce() async {
        await MainActor.run {
            let holder = Entity()
            let marker = Entity()
            let disc = Entity()
            let placeholder = ModelEntity(
                mesh: .generateSphere(radius: 0.2),
                materials: [UnlitMaterial(color: .white)]
            )
            holder.addChild(placeholder)
            holder.addChild(marker)
            holder.addChild(disc)
            GeoARSessionManager.applyPhysicalSize(
                2.5, to: placeholder, in: holder, marker: marker, disc: disc
            )
            placeholder.removeFromParent()

            let loaded = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(1, 2, 0.5)),
                materials: [UnlitMaterial(color: .white)]
            )
            holder.addChild(loaded)
            GeoARSessionManager.applyPhysicalSize(
                2.5, to: loaded, in: holder, marker: marker, disc: disc, force: true
            )
            XCTAssertEqual(loaded.scale.x, 2.5, accuracy: 0.0001)
            XCTAssertEqual(loaded.visualBounds(relativeTo: holder).extents.y,
                           5, accuracy: 0.0001)
            XCTAssertEqual(disc.scale.x, 0.55 * 2.5, accuracy: 0.0001)

            GeoARSessionManager.applyPhysicalSize(
                3, to: loaded, in: holder, marker: marker, disc: disc
            )
            XCTAssertEqual(loaded.scale.x, 3, accuracy: 0.0001)
            XCTAssertEqual(loaded.visualBounds(relativeTo: holder).extents.y,
                           6, accuracy: 0.0001)
            XCTAssertEqual(disc.scale.x, 0.55 * 3, accuracy: 0.0001)
        }
    }

    func testSavedScaleBuildsAtSameSizeOnAnotherSession() async throws {
        let drop = GeoDrop(content: .gift, message: "", latitude: 0, longitude: 0,
                           heightAboveGround: 0, scale: 2.25, colorHex: "#FFFFFF",
                           createdBy: "Author")
        let decoded = try JSONDecoder().decode(GeoDrop.self, from: JSONEncoder().encode(drop))
        await MainActor.run {
            let first = DropEntityFactory.makeEntity(for: drop, fullBright: false)
            let reopened = DropEntityFactory.makeEntity(for: decoded, fullBright: false)
            XCTAssertEqual(first.scale.x, 2.25, accuracy: 0.0001)
            XCTAssertEqual(reopened.scale.x, first.scale.x, accuracy: 0.0001)
            XCTAssertEqual(reopened.visualBounds(relativeTo: nil).extents.y,
                           first.visualBounds(relativeTo: nil).extents.y,
                           accuracy: 0.0001)
        }
    }
}
