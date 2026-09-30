import Foundation

/// Keeps committed placement fields authoritative until the asynchronous library
/// publication catches up. Other fields always come from the current library row.
struct AuthoredDropOverlay {
    private struct Placement: Equatable {
        let latitude: Double
        let longitude: Double
        let heightAboveGround: Double
        let scale: Double
        let facingDegrees: Double?
        let anchorMode: String

        init(_ drop: GeoDrop) {
            latitude = drop.latitude
            longitude = drop.longitude
            heightAboveGround = drop.heightAboveGround
            scale = drop.scale
            facingDegrees = drop.facingDegrees
            anchorMode = drop.anchorMode
        }

        func applying(to source: GeoDrop) -> GeoDrop {
            var result = source
            result.latitude = latitude
            result.longitude = longitude
            result.heightAboveGround = heightAboveGround
            result.scale = scale
            result.facingDegrees = facingDegrees
            result.anchorMode = anchorMode
            return result
        }
    }

    private struct Pending {
        let placement: Placement
        let order: UInt64
    }
    private var pending: [UUID: Pending] = [:]
    private var nextOrder: UInt64 = 0
    private let maxPending = 128

    mutating func stage(_ drop: GeoDrop) {
        nextOrder &+= 1
        pending[drop.id] = Pending(placement: Placement(drop), order: nextOrder)
        if pending.count > maxPending,
           let oldest = pending.min(by: { $0.value.order < $1.value.order })?.key {
            pending[oldest] = nil
        }
    }

    mutating func resolve(_ libraryDrop: GeoDrop) -> GeoDrop {
        guard let authored = pending[libraryDrop.id] else { return libraryDrop }
        if authored.placement == Placement(libraryDrop) {
            pending[libraryDrop.id] = nil
            return libraryDrop
        }
        return authored.placement.applying(to: libraryDrop)
    }

    mutating func retainOnly(_ ids: Set<UUID>) {
        pending = pending.filter { ids.contains($0.key) }
    }
}
