import Foundation

/// A geographic coordinate can be shared only when the explicit author's
/// projection has a fresh, sufficiently narrow estimate. This is separate from
/// the looser 10 m / 8° gate used to start VPS anchors for visual refinement.
/// Two metres is a cautious publication target for a nearby authored spot; it
/// still cannot establish exact contact with a surface on another device.
enum GeographicWritebackPolicy {
    static let maximumPublishedEstimateMeters = 2.0
    static let maximumPublishedYawDegrees = 5.0
    static let maximumMeasurementAge: TimeInterval = 1.5

    static func assessVPS(
        targetHorizontal: Double, cameraHorizontal: Double,
        yawDegrees: Double, distanceMeters: Double,
        measuredAt: Date, now: Date
    ) -> GeographicQuality? {
        let age = now.timeIntervalSince(measuredAt)
        guard targetHorizontal.isFinite, targetHorizontal > 0,
              cameraHorizontal.isFinite, cameraHorizontal > 0,
              yawDegrees.isFinite, (0...45).contains(yawDegrees),
              distanceMeters.isFinite, distanceMeters >= 0,
              age.isFinite, (-0.25...maximumMeasurementAge).contains(age)
        else { return nil }
        return GeographicQuality(
            source: GeographicQuality.Source.vpsProjection,
            sensorHorizontalAccuracyMeters: targetHorizontal,
            cameraHorizontalAccuracyMeters: cameraHorizontal,
            yawAccuracyDegrees: yawDegrees,
            projectionDistanceMeters: distanceMeters,
            measuredAt: measuredAt
        )
    }

    static func mayPublish(_ quality: GeographicQuality?, at now: Date) -> Bool {
        guard let quality,
              quality.source == GeographicQuality.Source.vpsProjection,
              let estimate = quality.horizontalEstimateMeters,
              let target = quality.sensorHorizontalAccuracyMeters,
              let camera = quality.cameraHorizontalAccuracyMeters,
              let yaw = quality.yawAccuracyDegrees,
              let distance = quality.projectionDistanceMeters,
              let measuredAt = quality.measuredAt
        else { return false }
        let age = now.timeIntervalSince(measuredAt)
        let recomputed = GeographicQuality.vpsEstimate(
            targetHorizontal: target, cameraHorizontal: camera,
            yawDegrees: yaw, distanceMeters: distance
        )
        return target.isFinite && target > 0 && camera.isFinite && camera > 0
            && yaw.isFinite && (0...maximumPublishedYawDegrees).contains(yaw)
            && distance.isFinite && distance >= 0
            && estimate.isFinite && estimate == recomputed
            && estimate <= maximumPublishedEstimateMeters
            && age.isFinite && (-0.25...maximumMeasurementAge).contains(age)
    }

    /// Estimates what a receiver may see at a given distance. The author's
    /// saved-coordinate estimate and the receiver's localization estimate are
    /// separate contributions; the latter grows with yaw and viewing distance.
    static func viewingEstimate(
        savedHorizontal: Double, cameraHorizontal: Double,
        yawDegrees: Double, distanceMeters: Double
    ) -> Double? {
        guard savedHorizontal.isFinite, savedHorizontal > 0,
              cameraHorizontal.isFinite, cameraHorizontal > 0,
              yawDegrees.isFinite, (0...45).contains(yawDegrees),
              distanceMeters.isFinite, distanceMeters >= 0
        else { return nil }
        return savedHorizontal + cameraHorizontal
            + distanceMeters * sin(yawDegrees * .pi / 180)
    }
}
