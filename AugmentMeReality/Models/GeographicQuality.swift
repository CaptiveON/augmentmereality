import Foundation

/// Evidence about a saved geographic coordinate. A visually stable AR raycast is
/// local to one tracking session; it does not by itself make latitude/longitude
/// accurate on another device. The numeric value is an estimate for discovery,
/// never a surveyed error bound or a promise of surface contact.
struct GeographicQuality: Codable, Equatable, Hashable, Sendable {
    enum Source {
        static let mapSelection = "mapSelection"
        static let mapSearch = "mapSearch"
        static let deviceFix = "deviceFix"
        static let vpsProjection = "vpsProjection"
        static let gpsProjection = "gpsProjection"
    }

    /// Kept as a string so a newer writer's source survives an older reader.
    var source: String
    var horizontalEstimateMeters: Double?
    /// The SDK's horizontal uncertainty for the projected target (or GPS fix).
    var sensorHorizontalAccuracyMeters: Double?
    /// ARCore's horizontal uncertainty for the camera used for projection.
    var cameraHorizontalAccuracyMeters: Double?
    var yawAccuracyDegrees: Double?
    var projectionDistanceMeters: Double?
    var measuredAt: Date?

    init(
        source: String, horizontalEstimateMeters: Double? = nil,
        sensorHorizontalAccuracyMeters: Double? = nil,
        cameraHorizontalAccuracyMeters: Double? = nil,
        yawAccuracyDegrees: Double? = nil,
        projectionDistanceMeters: Double? = nil, measuredAt: Date? = nil
    ) {
        self.source = source
        self.horizontalEstimateMeters = horizontalEstimateMeters
        self.sensorHorizontalAccuracyMeters = sensorHorizontalAccuracyMeters
        self.cameraHorizontalAccuracyMeters = cameraHorizontalAccuracyMeters
        self.yawAccuracyDegrees = yawAccuracyDegrees
        self.projectionDistanceMeters = projectionDistanceMeters
        self.measuredAt = measuredAt
        sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case source, horizontalEstimateMeters, sensorHorizontalAccuracyMeters
        case cameraHorizontalAccuracyMeters, yawAccuracyDegrees
        case projectionDistanceMeters, measuredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        // Damaged optional metadata must not quarantine an otherwise readable
        // drop. It loses its quantified status instead.
        horizontalEstimateMeters = try? c.decode(Double.self, forKey: .horizontalEstimateMeters)
        sensorHorizontalAccuracyMeters = try? c.decode(Double.self, forKey: .sensorHorizontalAccuracyMeters)
        cameraHorizontalAccuracyMeters = try? c.decode(Double.self, forKey: .cameraHorizontalAccuracyMeters)
        yawAccuracyDegrees = try? c.decode(Double.self, forKey: .yawAccuracyDegrees)
        projectionDistanceMeters = try? c.decode(Double.self, forKey: .projectionDistanceMeters)
        measuredAt = try? c.decode(Date.self, forKey: .measuredAt)
        sanitize()
    }

    private mutating func sanitize() {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source = "unknown" }
        if let value = sensorHorizontalAccuracyMeters,
           !value.isFinite || value <= 0 { sensorHorizontalAccuracyMeters = nil }
        if let value = cameraHorizontalAccuracyMeters,
           !value.isFinite || value <= 0 { cameraHorizontalAccuracyMeters = nil }
        if let value = yawAccuracyDegrees,
           !value.isFinite || !(0...45).contains(value) { yawAccuracyDegrees = nil }
        if let value = projectionDistanceMeters,
           !value.isFinite || value < 0 { projectionDistanceMeters = nil }
        if let date = measuredAt, !date.timeIntervalSince1970.isFinite { measuredAt = nil }

        // Never trust a serialized low estimate when its source components are
        // absent or contradictory. Map points have no calibrated uncertainty.
        switch source {
        case Source.vpsProjection:
            if measuredAt != nil,
               let target = sensorHorizontalAccuracyMeters,
               let camera = cameraHorizontalAccuracyMeters,
               let yaw = yawAccuracyDegrees,
               let range = projectionDistanceMeters {
                horizontalEstimateMeters = Self.vpsEstimate(
                    targetHorizontal: target, cameraHorizontal: camera,
                    yawDegrees: yaw, distanceMeters: range
                )
            } else {
                horizontalEstimateMeters = nil
            }
        case Source.deviceFix:
            horizontalEstimateMeters = measuredAt == nil
                ? nil : sensorHorizontalAccuracyMeters
            cameraHorizontalAccuracyMeters = nil
            yawAccuracyDegrees = nil
            projectionDistanceMeters = nil
        default:
            horizontalEstimateMeters = nil
        }
    }

    /// The target transform already reports uncertainty for its own WGS84
    /// coordinate. Compare that with camera uncertainty plus projected yaw
    /// displacement; adding target uncertainty to both would count it twice.
    static func vpsEstimate(
        targetHorizontal: Double, cameraHorizontal: Double,
        yawDegrees: Double, distanceMeters: Double
    ) -> Double {
        max(targetHorizontal,
            cameraHorizontal + distanceMeters * sin(yawDegrees * .pi / 180))
    }

    var disclosure: String {
        if let horizontalEstimateMeters {
            return String(format: "Location estimated ±%.1f m (%@)",
                          horizontalEstimateMeters, source == Source.vpsProjection ? "VPS" : "GPS")
        }
        switch source {
        case Source.mapSelection: return "Map-selected location · accuracy unmeasured"
        case Source.mapSearch: return "Search-result location · accuracy unmeasured"
        case Source.gpsProjection: return "GPS-projected location · accuracy unmeasured"
        default: return "Location accuracy unknown"
        }
    }
}
