import CoreLocation
import simd

/// Tangent-plane geodesy for Tier A placement: convert lat/lon deltas into local
/// east/north meters. Accurate to well under GPS error at the sub-kilometer ranges
/// this app renders at.
enum GeoMath {
    static let metersPerDegreeLatitude = 111_319.49

    /// East (x) / North (y) offset in meters from `origin` to `target`.
    static func enuOffset(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> SIMD2<Double> {
        let north = (target.latitude - origin.latitude) * metersPerDegreeLatitude
        let east = (target.longitude - origin.longitude)
            * metersPerDegreeLatitude
            * cos(origin.latitude * .pi / 180)
        return SIMD2(east, north)
    }

    /// Initial bearing from `origin` to `target` in degrees clockwise from true north (0–360).
    static func bearing(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = origin.latitude * .pi / 180
        let lat2 = target.latitude * .pi / 180
        let deltaLon = (target.longitude - origin.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Coordinate reached by traveling `distanceMeters` along `bearingDegrees` from `origin`.
    static func coordinate(
        from origin: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let radians = bearingDegrees * .pi / 180
        let north = distanceMeters * cos(radians)
        let east = distanceMeters * sin(radians)
        return CLLocationCoordinate2D(
            latitude: origin.latitude + north / metersPerDegreeLatitude,
            longitude: origin.longitude + east
                / (metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        )
    }

    /// Transit dead reckoning (§6.1): advance a GNSS fix along its course by its
    /// speed for the time elapsed since the fix. Prediction is capped at 8 s — past
    /// that (tunnel) the estimate is honestly frozen rather than extrapolated into
    /// fiction, and the HUD reports staleness.
    static func predicted(from location: CLLocation, at date: Date) -> CLLocationCoordinate2D {
        let elapsed = date.timeIntervalSince(location.timestamp)
        guard elapsed > 0, location.speed > 2, location.course >= 0 else {
            return location.coordinate
        }
        return coordinate(
            from: location.coordinate,
            bearingDegrees: location.course,
            distanceMeters: location.speed * min(elapsed, 8)
        )
    }

    /// "N", "NE", "E", … for a bearing in degrees.
    static func compassPoint(for bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return points[index]
    }

    /// "35 m" / "1.2 km" style distance label.
    static func distanceLabel(_ meters: CLLocationDistance) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1_000)
    }
}
