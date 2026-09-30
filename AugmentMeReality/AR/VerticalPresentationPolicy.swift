import Foundation

/// A geographic altitude is useful only with the same datum at the viewer.
/// A provisional discovery height is never a measured ground/roof elevation.
enum VerticalPresentationPolicy {
    struct Placement: Equatable {
        let worldY: Float
        let isProvisional: Bool
    }

    static func placement(
        vertical: VerticalPlacement?, offset: Double, cameraWorldY: Float,
        cameraEllipsoidalAltitude: Double?, cameraVerticalAccuracy: Double?,
        cameraMeasuredAt: Date?, now: Date
    ) -> Placement {
        let safeCameraY = cameraWorldY.isFinite ? cameraWorldY : 0
        let validOffset = offset.isFinite && GeoDrop.supportedHeightRange.contains(offset)
        let safeOffset = offset.isFinite
            ? min(max(offset, GeoDrop.supportedHeightRange.lowerBound),
                  GeoDrop.supportedHeightRange.upperBound) : 0
        if validOffset, let support = vertical?.usableResolvedSupportAltitudeMeters,
           let altitude = cameraEllipsoidalAltitude, altitude.isFinite,
           let accuracy = cameraVerticalAccuracy, accuracy.isFinite,
           accuracy > 0, accuracy <= 3,
           let measuredAt = cameraMeasuredAt,
           (-0.25...5).contains(now.timeIntervalSince(measuredAt)),
           let supportAccuracy = vertical?.verticalUncertaintyMeters,
           supportAccuracy <= 3 {
            let relativeY = support + safeOffset - altitude
            // Very distant vertical surfaces remain discovery-only. Never
            // clamp a known altitude and present the clamped value as resolved.
            if relativeY.isFinite, abs(relativeY) <= 100 {
                return Placement(worldY: safeCameraY + Float(relativeY), isProvisional: false)
            }
        }
        return Placement(worldY: safeCameraY + Float(safeOffset), isProvisional: true)
    }

    /// This is an app publication limit, not a surveyed accuracy guarantee.
    static func publishableSupport(
        altitudeWGS84: Double, uncertainty: Double, measuredAt: Date, now: Date
    ) -> VerticalPlacement? {
        guard altitudeWGS84.isFinite, abs(altitudeWGS84) <= 20_000,
              uncertainty.isFinite, uncertainty > 0, uncertainty <= 2,
              (-0.25...1.5).contains(now.timeIntervalSince(measuredAt)) else { return nil }
        return VerticalPlacement(
            reference: VerticalPlacement.Reference.localSupport,
            resolvedSupportAltitudeMeters: altitudeWGS84,
            verticalDatum: VerticalPlacement.Datum.wgs84Ellipsoid,
            verticalUncertaintyMeters: uncertainty, measuredAt: measuredAt,
            provenance: VerticalPlacement.Provenance.vpsProjection
        )
    }
}
