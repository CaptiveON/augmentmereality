import ARCore
import Combine
import Foundation
import simd

/// Limits the geometry payload owned by this pipeline. Bytes count vertex and
/// triangle-index storage, including builds that have not reached RealityKit.
/// RealityKit's private GPU allocations are not represented by this estimate.
struct StreetscapeMeshLimits: Sendable {
    let outstandingBuilds: Int
    let residentMeshes: Int
    let residentTriangles: Int
    let residentBytes: Int
    let verticesPerMesh: Int
    let trianglesPerMesh: Int
    let verticesPerUpdate: Int
    let trianglesPerUpdate: Int

    static let live = Self(
        outstandingBuilds: 8,
        residentMeshes: 24,
        residentTriangles: 160_000,
        residentBytes: 8 * 1024 * 1024,
        verticesPerMesh: 32_000,
        trianglesPerMesh: 60_000,
        verticesPerUpdate: 1_024,
        trianglesPerUpdate: 1_024
    )
}

/// Owns only Swift value arrays. It is the sole mesh input allowed onto the
/// preparation queue; no GAR object or pointer crosses that boundary.
struct StreetscapeMeshSnapshot: Sendable {
    let positions: [SIMD3<Float>]
    let indices: [UInt32]

    enum Invalid: Error, Equatable, Sendable {
        case empty
        case nonFiniteVertex
        case indexOutOfBounds
        case degenerateTriangle
    }

    /// This linear scan is intentionally off the main actor in production.
    func validate() -> Invalid? {
        guard !positions.isEmpty, !indices.isEmpty, indices.count.isMultiple(of: 3) else {
            return .empty
        }
        for point in positions where !point.x.isFinite || !point.y.isFinite || !point.z.isFinite {
            return .nonFiniteVertex
        }
        for offset in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[offset], b = indices[offset + 1], c = indices[offset + 2]
            guard Int(a) < positions.count, Int(b) < positions.count,
                  Int(c) < positions.count else {
                return .indexOutOfBounds
            }
            guard a != b, b != c, a != c else { return .degenerateTriangle }
        }
        return nil
    }
}

/// A policy reset may admit the same ID and work token again after shedding
/// memory. The unique ticket distinguishes that new build from an older result.
struct StreetscapeBuildRegistry {
    struct Key: Equatable, Sendable {
        let token: PerceptionWorkAdmission.Token
        let ticket: UUID
    }
    private(set) var current: [UUID: Key] = [:]

    subscript(id: UUID) -> Key? { current[id] }

    @discardableResult
    mutating func begin(id: UUID, key: Key) -> Bool {
        guard current[id] == nil else { return false }
        current[id] = key
        return true
    }

    func accepts(id: UUID, key: Key) -> Bool { current[id] == key }

    @discardableResult
    mutating func retire(id: UUID, key: Key) -> Bool {
        guard accepts(id: id, key: key) else { return false }
        current[id] = nil
        return true
    }

    mutating func clear() { current.removeAll() }
}

/// Malformed SDK snapshots should not cause a retry every GAR frame, but a
/// later snapshot of the same building may be usable. Only IDs in the latest
/// tracked frame remain cached, and every rejection has a bounded retry date.
struct StreetscapeMeshRetryGate {
    private(set) var retryAfter: [UUID: TimeInterval] = [:]
    let delay: TimeInterval

    init(delay: TimeInterval = 15) { self.delay = delay }

    func allows(_ id: UUID, at uptime: TimeInterval) -> Bool {
        uptime >= (retryAfter[id] ?? -.infinity)
    }

    mutating func reject(_ id: UUID, at uptime: TimeInterval) {
        retryAfter[id] = uptime + delay
    }

    mutating func retainOnly(_ seen: Set<UUID>) {
        retryAfter = retryAfter.filter { seen.contains($0.key) }
    }

    mutating func clear() { retryAfter.removeAll() }
}

enum StreetscapeMeshGenerationDeadline {
    /// `first` completes after one resource; timeout cancels the upstream
    /// RealityKit request before the owner retires its build ticket.
    static func applying<P: Publisher>(to publisher: P, seconds: TimeInterval = 30)
        -> AnyPublisher<P.Output, Error> {
        publisher.mapError { $0 as Error }
            .first()
            .receive(on: DispatchQueue.main)
            .timeout(.seconds(seconds), scheduler: DispatchQueue.main, customError: {
                NSError(domain: "AugmentMeReality.StreetscapeMesh", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Streetscape mesh generation timed out"])
            })
            .eraseToAnyPublisher()
    }
}

/// The installed SDK exposes GARMesh's vertex and triangle storage as raw
/// pointers. This adapter and its capture cursor stay on the main actor, where
/// GARSession.update and the containing GARFrame are consumed.
@MainActor
protocol StreetscapeMeshSource: AnyObject {
    var vertexCount: Int { get }
    var triangleCount: Int { get }
    func vertex(at index: Int) -> SIMD3<Float>
    func triangle(at index: Int) -> SIMD3<UInt32>
}

@MainActor
final class GARStreetscapeMeshSource: StreetscapeMeshSource {
    private let mesh: GARMesh
    init(_ mesh: GARMesh) { self.mesh = mesh }
    var vertexCount: Int { Int(mesh.vertexCount) }
    var triangleCount: Int { Int(mesh.triangleCount) }
    func vertex(at index: Int) -> SIMD3<Float> {
        let point = mesh.vertices[index]
        return SIMD3(point.x, point.y, point.z)
    }
    func triangle(at index: Int) -> SIMD3<UInt32> {
        let face = mesh.triangles[index]
        return SIMD3(face.indices.0, face.indices.1, face.indices.2)
    }
}

@MainActor
final class StreetscapeMeshCapture {
    private let source: any StreetscapeMeshSource
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var indices: [UInt32] = []
    private(set) var copiedVertices = 0
    private(set) var copiedTriangles = 0

    init(source: any StreetscapeMeshSource) {
        self.source = source
        positions.reserveCapacity(min(source.vertexCount, StreetscapeMeshLimits.live.verticesPerUpdate))
        indices.reserveCapacity(min(source.triangleCount, StreetscapeMeshLimits.live.trianglesPerUpdate) * 3)
    }

    var isComplete: Bool {
        copiedVertices == source.vertexCount && copiedTriangles == source.triangleCount
    }

    /// The caller shares these allowances across all captures in one GAR update.
    /// A large building therefore cannot copy its whole raw buffer in one frame.
    func advance(vertices vertexAllowance: inout Int, triangles triangleAllowance: inout Int) {
        let vertexEnd = min(source.vertexCount, copiedVertices + vertexAllowance)
        while copiedVertices < vertexEnd {
            positions.append(source.vertex(at: copiedVertices))
            copiedVertices += 1
            vertexAllowance -= 1
        }
        guard copiedVertices == source.vertexCount else { return }
        let triangleEnd = min(source.triangleCount, copiedTriangles + triangleAllowance)
        while copiedTriangles < triangleEnd {
            let face = source.triangle(at: copiedTriangles)
            indices.append(face.x)
            indices.append(face.y)
            indices.append(face.z)
            copiedTriangles += 1
            triangleAllowance -= 1
        }
    }

    func snapshot() -> StreetscapeMeshSnapshot? {
        guard isComplete else { return nil }
        return StreetscapeMeshSnapshot(positions: positions, indices: indices)
    }
}

/// Counts reservations as resident until their real completion. Clearing a
/// scene removes installed meshes; an obsolete worker keeps its reservation.
struct StreetscapeMeshLedger {
    struct Footprint: Equatable {
        let triangles: Int
        let bytes: Int
    }
    struct Totals: Equatable {
        let meshes: Int
        let triangles: Int
        let bytes: Int
    }
    enum Rejection: Error, Equatable {
        case invalidCounts
        case oversizedMesh
        case arithmeticOverflow
        case residentLimit
    }

    let limits: StreetscapeMeshLimits
    private(set) var reservations: [UUID: Footprint] = [:]
    private(set) var installed: [UUID: Footprint] = [:]

    var totals: Totals {
        let footprints = Array(reservations.values) + Array(installed.values)
        return Totals(meshes: footprints.count,
                      triangles: footprints.reduce(0) { $0 + $1.triangles },
                      bytes: footprints.reduce(0) { $0 + $1.bytes })
    }

    func footprint(vertices: Int, triangles: Int) -> Result<Footprint, Rejection> {
        guard vertices > 0, triangles > 0 else { return .failure(.invalidCounts) }
        guard vertices <= limits.verticesPerMesh, triangles <= limits.trianglesPerMesh else {
            return .failure(.oversizedMesh)
        }
        let (vertexBytes, vertexOverflow) = vertices.multipliedReportingOverflow(
            by: MemoryLayout<SIMD3<Float>>.stride)
        let (indexBytes, indexOverflow) = triangles.multipliedReportingOverflow(by: 3 * MemoryLayout<UInt32>.stride)
        let (bytes, sumOverflow) = vertexBytes.addingReportingOverflow(indexBytes)
        guard !vertexOverflow, !indexOverflow, !sumOverflow else {
            return .failure(.arithmeticOverflow)
        }
        return .success(Footprint(triangles: triangles, bytes: bytes))
    }

    mutating func reserve(ticket: UUID, vertices: Int, triangles: Int) -> Rejection? {
        guard reservations[ticket] == nil else { return .residentLimit }
        let admittedFootprint: Footprint
        switch footprint(vertices: vertices, triangles: triangles) {
        case .failure(let rejection): return rejection
        case .success(let accepted): admittedFootprint = accepted
        }
        guard admittedFootprint.triangles <= limits.residentTriangles,
              admittedFootprint.bytes <= limits.residentBytes else { return .oversizedMesh }
        let current = totals
        let (trianglesAfter, triangleOverflow) = current.triangles.addingReportingOverflow(admittedFootprint.triangles)
        let (bytesAfter, byteOverflow) = current.bytes.addingReportingOverflow(admittedFootprint.bytes)
        guard !triangleOverflow, !byteOverflow else { return .arithmeticOverflow }
        guard current.meshes < limits.residentMeshes,
              trianglesAfter <= limits.residentTriangles,
              bytesAfter <= limits.residentBytes else { return .residentLimit }
        reservations[ticket] = admittedFootprint
        return nil
    }

    mutating func install(ticket: UUID, id: UUID) -> Bool {
        guard installed[id] == nil, let footprint = reservations.removeValue(forKey: ticket) else {
            return false
        }
        installed[id] = footprint
        return true
    }

    mutating func finish(ticket: UUID) { reservations[ticket] = nil }
    mutating func remove(id: UUID) { installed[id] = nil }
    mutating func removeAllInstalled() { installed.removeAll() }
}
