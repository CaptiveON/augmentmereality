import Combine
import XCTest
@testable import AugmentMeReality

@MainActor
final class StreetscapeMeshPipelineTests: XCTestCase {
    private final class FakeSource: StreetscapeMeshSource {
        let points: [SIMD3<Float>]
        let faces: [SIMD3<UInt32>]
        private(set) var vertexReads = 0
        private(set) var triangleReads = 0

        init(points: [SIMD3<Float>], faces: [SIMD3<UInt32>]) {
            self.points = points
            self.faces = faces
        }
        var vertexCount: Int { points.count }
        var triangleCount: Int { faces.count }
        func vertex(at index: Int) -> SIMD3<Float> {
            vertexReads += 1
            return points[index]
        }
        func triangle(at index: Int) -> SIMD3<UInt32> {
            triangleReads += 1
            return faces[index]
        }
    }

    private func limits(meshes: Int = 2, triangles: Int = 4,
                        bytes: Int = 1_024, verticesPerMesh: Int = 12,
                        trianglesPerMesh: Int = 4) -> StreetscapeMeshLimits {
        .init(outstandingBuilds: 2, residentMeshes: meshes,
              residentTriangles: triangles, residentBytes: bytes,
              verticesPerMesh: verticesPerMesh, trianglesPerMesh: trianglesPerMesh,
              verticesPerUpdate: 2, trianglesPerUpdate: 1)
    }

    func testProductionCaptureCopiesOnlyAllowanceAndValidatesOwnedSnapshot() throws {
        let source = FakeSource(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            faces: [SIMD3(0, 1, 2)])
        let capture = StreetscapeMeshCapture(source: source)
        var vertices = 2, triangles = 1
        capture.advance(vertices: &vertices, triangles: &triangles)
        XCTAssertEqual(source.vertexReads, 2)
        XCTAssertEqual(source.triangleReads, 0)
        XCTAssertNil(capture.snapshot())

        vertices = 2
        capture.advance(vertices: &vertices, triangles: &triangles)
        XCTAssertEqual(source.vertexReads, 3)
        XCTAssertEqual(source.triangleReads, 1)
        XCTAssertNil(try XCTUnwrap(capture.snapshot()).validate())
    }

    func testMalformedSnapshotRejectsInvalidVertexIndexAndTriangle() {
        let valid = [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        XCTAssertEqual(StreetscapeMeshSnapshot(
            positions: [SIMD3(.nan, 0, 0)] + valid,
            indices: [1, 2, 3]).validate(), .nonFiniteVertex)
        XCTAssertEqual(StreetscapeMeshSnapshot(
            positions: valid, indices: [0, 1, 3]).validate(), .indexOutOfBounds)
        XCTAssertEqual(StreetscapeMeshSnapshot(
            positions: valid, indices: [0, 1, 1]).validate(), .degenerateTriangle)
        XCTAssertEqual(StreetscapeMeshSnapshot(
            positions: valid, indices: []).validate(), .empty)
    }

    func testCountsRejectedBeforeAnyRawBufferReadOrAllocation() {
        var ledger = StreetscapeMeshLedger(limits: limits())
        let ticket = UUID()
        XCTAssertEqual(ledger.reserve(ticket: ticket, vertices: 0, triangles: 1), .invalidCounts)
        XCTAssertEqual(ledger.reserve(ticket: ticket, vertices: 100, triangles: 1), .oversizedMesh)
        XCTAssertEqual(ledger.reserve(ticket: ticket, vertices: 3, triangles: 100), .oversizedMesh)
        XCTAssertEqual(ledger.totals.meshes, 0)

        let huge = limits(meshes: Int.max, triangles: Int.max, bytes: Int.max,
                          verticesPerMesh: Int.max, trianglesPerMesh: Int.max)
        ledger = StreetscapeMeshLedger(limits: huge)
        XCTAssertEqual(ledger.reserve(ticket: ticket, vertices: Int.max, triangles: 1),
                       .arithmeticOverflow)
        XCTAssertEqual(ledger.reserve(ticket: ticket, vertices: 3, triangles: Int.max),
                       .arithmeticOverflow)
    }

    func testResidentLimitsIncludeQueuedBuildsAndInstalledGeometry() {
        var ledger = StreetscapeMeshLedger(limits: limits(meshes: 2, triangles: 2, bytes: 128))
        let first = UUID(), second = UUID(), third = UUID(), installedID = UUID()
        XCTAssertNil(ledger.reserve(ticket: first, vertices: 3, triangles: 1))
        XCTAssertTrue(ledger.install(ticket: first, id: installedID))
        XCTAssertNil(ledger.reserve(ticket: second, vertices: 3, triangles: 1))
        XCTAssertEqual(ledger.totals, .init(meshes: 2, triangles: 2,
                                           bytes: 2 * (3 * MemoryLayout<SIMD3<Float>>.stride + 12)))
        XCTAssertEqual(ledger.reserve(ticket: third, vertices: 3, triangles: 1), .residentLimit)
        ledger.remove(id: installedID)
        XCTAssertNil(ledger.reserve(ticket: third, vertices: 3, triangles: 1))
        XCTAssertEqual(ledger.totals.meshes, 2)
    }

    func testInvalidationRetainsOldWorkerReservationUntilItsOwnCompletion() throws {
        var admission = PerceptionWorkAdmission()
        admission.setAllowed(true, generation: 1)
        let oldToken = try XCTUnwrap(admission.token)
        var ledger = StreetscapeMeshLedger(limits: limits(meshes: 2))
        let oldTicket = UUID(), newTicket = UUID(), newID = UUID()
        XCTAssertNil(ledger.reserve(ticket: oldTicket, vertices: 3, triangles: 1))

        admission.setAllowed(false, generation: 2)
        XCTAssertFalse(admission.accepts(oldToken))
        ledger.removeAllInstalled() // scene reset cannot free a worker's memory
        XCTAssertEqual(ledger.totals.meshes, 1)
        admission.setAllowed(true, generation: 2)
        XCTAssertNil(ledger.reserve(ticket: newTicket, vertices: 3, triangles: 1))
        ledger.finish(ticket: oldTicket)
        ledger.finish(ticket: oldTicket) // duplicate old completion is harmless
        XCTAssertEqual(ledger.totals.meshes, 1)
        XCTAssertTrue(ledger.install(ticket: newTicket, id: newID))
        XCTAssertEqual(ledger.totals.meshes, 1)
    }

    func testMemoryPressureReadmitsSameTokenWithoutAcceptingOldResult() throws {
        var admission = PerceptionWorkAdmission()
        admission.setAllowed(true, generation: 7)
        let token = try XCTUnwrap(admission.token)
        let id = UUID(), oldTicket = UUID(), newTicket = UUID()
        var registry = StreetscapeBuildRegistry()
        let old = StreetscapeBuildRegistry.Key(token: token, ticket: oldTicket)
        let new = StreetscapeBuildRegistry.Key(token: token, ticket: newTicket)
        XCTAssertTrue(registry.begin(id: id, key: old))
        registry.clear() // production memory-pressure edge; token is unchanged
        XCTAssertTrue(registry.begin(id: id, key: new))
        XCTAssertFalse(registry.accepts(id: id, key: old))
        XCTAssertFalse(registry.retire(id: id, key: old))
        XCTAssertTrue(registry.accepts(id: id, key: new))
        XCTAssertTrue(registry.retire(id: id, key: new))
    }

    func testMalformedSameIDRetriesAfterCooldownOrNewGeneration() {
        let id = UUID(), departed = UUID()
        var gate = StreetscapeMeshRetryGate(delay: 15)
        XCTAssertTrue(gate.allows(id, at: 100))
        gate.reject(id, at: 100)
        XCTAssertFalse(gate.allows(id, at: 114.9))
        XCTAssertTrue(gate.allows(id, at: 115)) // later SDK snapshot may be valid
        gate.reject(departed, at: 100)
        gate.retainOnly([id])
        XCTAssertNil(gate.retryAfter[departed])
        gate.clear() // admission generation changed while ID stayed visible
        XCTAssertTrue(gate.allows(id, at: 101))
    }

    func testSilentRealityKitPublisherHasDeadlineAndCancelsUpstream() async {
        let finished = expectation(description: "bounded mesh generation")
        let cancelled = expectation(description: "upstream request cancelled")
        let stalled = PassthroughSubject<Int, Error>()
        let subscription = StreetscapeMeshGenerationDeadline.applying(
            to: stalled.handleEvents(receiveCancel: { cancelled.fulfill() }), seconds: 0.03
        ).sink(receiveCompletion: { completion in
            guard case .failure(let error) = completion else {
                XCTFail("A silent mesh generator must fail"); return
            }
            XCTAssertEqual((error as NSError).domain, "AugmentMeReality.StreetscapeMesh")
            finished.fulfill()
        }, receiveValue: { _ in XCTFail("A silent mesh generator has no resource") })
        await fulfillment(of: [finished, cancelled], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testDiscardedPartialCaptureDoesNotReadSourceAgain() {
        let source = FakeSource(points: Array(repeating: SIMD3<Float>(1, 0, 0), count: 8),
                                faces: [SIMD3(0, 1, 2)])
        var capture: StreetscapeMeshCapture? = StreetscapeMeshCapture(source: source)
        var vertices = 2, triangles = 1
        capture?.advance(vertices: &vertices, triangles: &triangles)
        XCTAssertEqual(source.vertexReads, 2)
        capture = nil // generation invalidation drops the sole SDK-owning cursor
        XCTAssertEqual(source.vertexReads, 2)
        XCTAssertEqual(source.triangleReads, 0)
    }
}
