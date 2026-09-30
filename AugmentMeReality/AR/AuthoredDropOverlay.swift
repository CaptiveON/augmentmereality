import Foundation

/// Keeps committed placement fields authoritative until the asynchronous library
/// publication catches up. Other fields always come from the current library row.
struct AuthoredDropOverlay {
    struct Placement: Equatable {
        let latitude: Double
        let longitude: Double
        let geographicQuality: GeographicQuality?
        let heightAboveGround: Double
        let verticalPlacement: VerticalPlacement?
        let scale: Double
        let facingDegrees: Double?
        let anchorMode: String

        init(_ drop: GeoDrop) {
            latitude = drop.latitude
            longitude = drop.longitude
            geographicQuality = drop.geographicQuality
            heightAboveGround = drop.heightAboveGround
            verticalPlacement = drop.verticalPlacement
            scale = drop.scale
            facingDegrees = drop.facingDegrees
            anchorMode = drop.anchorMode
        }

        func applying(to source: GeoDrop) -> GeoDrop {
            var result = source
            result.latitude = latitude
            result.longitude = longitude
            result.geographicQuality = geographicQuality
            result.heightAboveGround = heightAboveGround
            result.verticalPlacement = verticalPlacement
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

    /// An asynchronous save may fail after a newer edit has been staged. Retire
    /// only the failed placement, leaving the newer author's intent intact.
    mutating func discardIfMatching(_ drop: GeoDrop) {
        guard pending[drop.id]?.placement == Placement(drop) else { return }
        pending[drop.id] = nil
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
