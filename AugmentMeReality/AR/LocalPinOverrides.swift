import Foundation
import simd

/// An authored raycast can be exact in this AR world frame while its geographic
/// coordinate is too uncertain to publish. Keep the local placement through
/// library refreshes; the manager separately freezes its holder against GPS and
/// VPS repositioning. A camera reset ends this world frame and clears the map.
struct LocalPinOverrides {
    private struct Entry {
        var placement: AuthoredDropOverlay.Placement
        var worldTransform: simd_float4x4
    }
    private var entries: [UUID: Entry] = [:]

    var ids: Set<UUID> { Set(entries.keys) }

    func contains(_ id: UUID) -> Bool { entries[id] != nil }

    func worldTransform(for id: UUID) -> simd_float4x4? {
        entries[id]?.worldTransform
    }

    func resolve(_ stored: GeoDrop) -> GeoDrop {
        entries[stored.id]?.placement.applying(to: stored) ?? stored
    }

    mutating func stage(_ local: GeoDrop, worldTransform: simd_float4x4) {
        entries[local.id] = Entry(
            placement: AuthoredDropOverlay.Placement(local),
            worldTransform: worldTransform
        )
    }

    mutating func update(_ local: GeoDrop, worldTransform: simd_float4x4) {
        guard entries[local.id] != nil else { return }
        stage(local, worldTransform: worldTransform)
    }

    mutating func remove(_ id: UUID) { entries[id] = nil }

    mutating func reset() { entries.removeAll() }
}
