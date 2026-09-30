import Foundation
import simd
import XCTest
@testable import AugmentMeReality

final class SupportSurfacePolicyTests: XCTestCase {
    private let now: TimeInterval = 1_000
    private let session = 7

    private func plane(
        y: Float = 0, normal: SIMD3<Float> = [0, 1, 0],
        footprint: [SIMD2<Float>]? = nil,
        timestamp: TimeInterval = 999.9, generation: Int = 7,
        id: UUID? = UUID()
    ) -> SupportSurfaceHit {
        SupportSurfaceHit(
            worldPosition: [0, y, 0], worldNormal: normal,
            source: .planeGeometry, surfaceID: id,
            footprintXZ: footprint ?? [
                [-1, -1], [1, -1], [1, 1], [-1, 1]
            ], frameTimestamp: timestamp, sessionGeneration: generation
        )
    }

    func testPlaneRequiresTargetWithinMeasuredFootprint() {
        let good = plane()
        XCTAssertNotNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.4, 0], from: [good],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
        let unrelated = plane(footprint: [
            [2, -1], [4, -1], [4, 1], [2, 1]
        ])
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.4, 0], from: [unrelated],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.4, 0], from: [plane(id: nil)],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
        let huge = plane(footprint: [
            [-100, -100], [100, -100], [100, 100], [-100, 100]
        ])
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.4, 0], from: [huge],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
    }

    func testRejectsStaleWrongSessionSlopeAndDistantSupport() {
        let target: SIMD3<Float> = [0, 0.4, 0]
        let invalid = [
            plane(timestamp: 999.5),
            plane(generation: 6),
            plane(normal: [0.5, 0.866, 0]),
            SupportSurfaceHit(
                worldPosition: [2, 0, 0], worldNormal: [0, 1, 0],
                source: .planeGeometry, surfaceID: UUID(),
                footprintXZ: [[-1, -1], [3, -1], [3, 1], [-1, 1]],
                frameTimestamp: 999.9, sessionGeneration: 7
            )
        ]
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: target, from: invalid, sessionGeneration: session,
            now: now, expectedSupportY: 0
        ))
    }

    func testWrongFloorIsRejectedWhenHeightKnownOrAmbiguous() {
        let low = plane(y: 0)
        let high = plane(y: 3)
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 3, 0], from: [low],
            sessionGeneration: session, now: now, expectedSupportY: 3
        ))
        let chosen = SupportSurfacePolicy.bestHit(
            for: [0, 3, 0], from: [low, high],
            sessionGeneration: session, now: now, expectedSupportY: 3
        )
        XCTAssertEqual(chosen?.worldPosition.y, 3)
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 3, 0], from: [low],
            sessionGeneration: session, now: now
        ), "a lone plane one storey below is not enough for a snap")
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 1.8, 0], from: [low, plane(y: 0.8)],
            sessionGeneration: session, now: now
        ), "without target support height, two support levels cannot be disambiguated")
    }

    func testMeshRequiresDirectRaycastProof() {
        let unproven = SupportSurfaceHit(
            worldPosition: [0, 0, 0], worldNormal: [0, 1, 0],
            source: .meshRaycast, frameTimestamp: 999.9,
            sessionGeneration: session
        )
        XCTAssertNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.005, 0], from: [unproven],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
        let measured = SupportSurfaceHit(
            worldPosition: [0, 0, 0], worldNormal: [0, 1, 0],
            source: .meshRaycast, isDirectMeshRayHit: true,
            frameTimestamp: 999.9, sessionGeneration: session
        )
        XCTAssertNotNil(SupportSurfacePolicy.bestHit(
            for: [0, 0.005, 0], from: [measured],
            sessionGeneration: session, now: now, expectedSupportY: 0
        ))
    }

    func testGroundedRelocationUpdatesRelativeHeightAndCueTogether() throws {
        let hit = plane(y: 4)
        var prior = GeoDrop(heightAboveGround: 6, anchorMode: "ground")
        prior.verticalPlacement = VerticalPlacement(reference: VerticalPlacement.Reference.terrain)
        let placement = try XCTUnwrap(GroundedSupportPlacement(
            drop: prior, support: hit,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        XCTAssertEqual(placement.drop.heightAboveGround, 0.005, accuracy: 0.0001)
        XCTAssertEqual(placement.drop.verticalReference, VerticalPlacement.Reference.localSupport)
        XCTAssertNil(placement.drop.verticalPlacement?.usableResolvedSupportAltitudeMeters)
        XCTAssertEqual(placement.holderWorldPosition.y, 4.005, accuracy: 0.0001)
        XCTAssertEqual(placement.groundLockBaseY, placement.holderWorldPosition.y)
        XCTAssertEqual(
            placement.holderWorldPosition.y + placement.groundingDiscLocalY,
            4.04, accuracy: 0.0001,
            "the contact cue moves to this support, not the old terrain height"
        )
    }
}
