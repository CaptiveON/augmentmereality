import Foundation
import simd

/// Ephemeral evidence from the *current* AR session. World coordinates and
/// plane IDs must never be serialized into `VerticalPlacement` as altitude.
struct SupportSurfaceHit {
    enum Source { case planeGeometry, meshRaycast }

    let worldPosition: SIMD3<Float>
    let worldNormal: SIMD3<Float>
    let source: Source
    /// Required for plane geometry, normally the ARPlaneAnchor identifier.
    let surfaceID: UUID?
    /// Ordered world-space X/Z boundary vertices for `.planeGeometry`.
    let footprintXZ: [SIMD2<Float>]?
    /// True only when `worldPosition` came from an actual scene mesh raycast.
    let isDirectMeshRayHit: Bool
    /// ARFrame.timestamp, in the same uptime clock as `now`.
    let frameTimestamp: TimeInterval
    let sessionGeneration: Int

    init(
        worldPosition: SIMD3<Float>, worldNormal: SIMD3<Float>, source: Source,
        surfaceID: UUID? = nil, footprintXZ: [SIMD2<Float>]? = nil,
        isDirectMeshRayHit: Bool = false, frameTimestamp: TimeInterval,
        sessionGeneration: Int
    ) {
        self.worldPosition = worldPosition
        self.worldNormal = worldNormal
        self.source = source
        self.surfaceID = surfaceID
        self.footprintXZ = footprintXZ
        self.isDirectMeshRayHit = isDirectMeshRayHit
        self.frameTimestamp = frameTimestamp
        self.sessionGeneration = sessionGeneration
    }
}

/// Admits a support only if fresh measured geometry actually covers the target.
/// If no expected height is supplied, competing floors are ambiguous and none
/// wins. Caller can keep the old pose as provisional when this returns nil.
enum SupportSurfacePolicy {
    static func bestHit(
        for targetWorldPosition: SIMD3<Float>, from hits: [SupportSurfaceHit],
        sessionGeneration: Int, now: TimeInterval,
        expectedSupportY: Float? = nil
    ) -> SupportSurfaceHit? {
        guard finite(targetWorldPosition), now.isFinite,
              expectedSupportY.map({ $0.isFinite }) ?? true else { return nil }
        let eligible = hits.filter { hit in
            guard hit.sessionGeneration == sessionGeneration,
                  hit.frameTimestamp.isFinite,
                  now - hit.frameTimestamp >= -0.05,
                  now - hit.frameTimestamp <= 0.25,
                  finite(hit.worldPosition), finite(hit.worldNormal) else { return false }

            let normalLength = simd_length(hit.worldNormal)
            guard normalLength.isFinite, normalLength > 0.5,
                  hit.worldNormal.y / normalLength >= 0.94 else { return false }
            let dx = hit.worldPosition.x - targetWorldPosition.x
            let dz = hit.worldPosition.z - targetWorldPosition.z
            guard dx * dx + dz * dz <= 0.35 * 0.35 else { return false }
            if let expectedSupportY {
                guard abs(hit.worldPosition.y - expectedSupportY) <= 0.45 else { return false }
            } else {
                let drop = targetWorldPosition.y - hit.worldPosition.y
                // An unhinted downward snap can only claim a nearby support.
                // A plane one storey below may cover the same X/Z footprint.
                guard (-0.15...2.5).contains(drop) else { return false }
            }

            switch hit.source {
            case .planeGeometry:
                guard hit.surfaceID != nil, let footprint = hit.footprintXZ,
                      validFootprint(footprint),
                      contains(SIMD2(targetWorldPosition.x, targetWorldPosition.z),
                               in: footprint),
                      contains(SIMD2(hit.worldPosition.x, hit.worldPosition.z),
                               in: footprint) else { return false }
            case .meshRaycast:
                guard hit.isDirectMeshRayHit else { return false }
            }
            return true
        }
        guard !eligible.isEmpty else { return nil }
        if expectedSupportY == nil,
           let lowest = eligible.map(\.worldPosition.y).min(),
           let highest = eligible.map(\.worldPosition.y).max(),
           highest - lowest > 0.6 {
            return nil
        }
        return eligible.min { lhs, rhs in
            let l = horizontalDistanceSquared(lhs.worldPosition, targetWorldPosition)
            let r = horizontalDistanceSquared(rhs.worldPosition, targetWorldPosition)
            if l != r { return l < r }
            return lhs.frameTimestamp > rhs.frameTimestamp
        }
    }

    private static func finite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private static func horizontalDistanceSquared(
        _ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>
    ) -> Float {
        let dx = lhs.x - rhs.x
        let dz = lhs.z - rhs.z
        return dx * dx + dz * dz
    }

    private static func validFootprint(_ polygon: [SIMD2<Float>]) -> Bool {
        guard (3...128).contains(polygon.count),
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let xs = polygon.map(\.x)
        let zs = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max(),
              maxX - minX <= 30, maxZ - minZ <= 30 else { return false }
        var twiceArea: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        return twiceArea.isFinite && abs(twiceArea) >= 0.02
    }

    private static func contains(_ point: SIMD2<Float>, in polygon: [SIMD2<Float>]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            // Boundary points count as support, allowing small triangulation
            // and floating-point differences at the measured plane edge.
            let edge = b - a
            let toPoint = point - a
            let lengthSquared = simd_length_squared(edge)
            if lengthSquared > 0 {
                let t = max(0, min(1, simd_dot(toPoint, edge) / lengthSquared))
                if simd_length_squared(toPoint - t * edge) <= 0.0025 { return true }
            }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
        }
        return inside
    }
}

/// One decision carries the holder, cue and relative-height edit together.
/// The local hit establishes contact in this session, not geographic altitude.
struct GroundedSupportPlacement {
    let drop: GeoDrop
    let holderWorldPosition: SIMD3<Float>
    let groundingDiscLocalY: Float
    let groundLockBaseY: Float

    init?(
        drop: GeoDrop, support: SupportSurfaceHit,
        measuredAt: Date, clearanceMeters: Float = 0.005
    ) {
        guard clearanceMeters.isFinite, (0...0.1).contains(clearanceMeters),
              measuredAt.timeIntervalSince1970.isFinite,
              support.worldPosition.x.isFinite,
              support.worldPosition.y.isFinite,
              support.worldPosition.z.isFinite else { return nil }
        let position = SIMD3(
            support.worldPosition.x,
            support.worldPosition.y + clearanceMeters,
            support.worldPosition.z
        )
        guard position.y.isFinite else { return nil }
        var updated = drop
        updated.heightAboveGround = Double(clearanceMeters)
        updated.verticalPlacement = VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            measuredAt: measuredAt,
            provenance: VerticalPlacement.Provenance.localARRaycast
        )
        self.drop = updated
        holderWorldPosition = position
        groundingDiscLocalY = support.worldPosition.y + 0.04 - position.y
        groundLockBaseY = position.y
    }
}
