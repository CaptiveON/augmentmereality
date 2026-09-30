import CoreLocation
import simd

/// WGS84 local-tangent geodesy. Offsets are ECEF chords projected onto east and
/// north at the origin. At the app's 2 km AR radius, this differs from a WGS84
/// geodesic by less than 1 cm. Checked operations support 5 km at every valid
/// latitude, including poles and antimeridian crossings.
enum GeoMath {
    static let maxSupportedOffsetMeters = 5_000.0

    private static let a = 6_378_137.0
    private static let f = 1 / 298.257_223_563
    private static let b = a * (1 - f)
    private static let e2 = f * (2 - f)

    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }

    /// East (x) and north (y) metres in the origin's WGS84 tangent frame.
    /// Returns nil for invalid input or a target beyond the supported range.
    static func checkedENUOffset(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> SIMD2<Double>? {
        guard isValid(origin), isValid(target) else { return nil }
        let delta = ecef(target) - ecef(origin)
        guard simd_length(delta) <= maxSupportedOffsetMeters + 0.001 else { return nil }
        let (east, north) = axes(at: origin)
        return SIMD2(simd_dot(delta, east), simd_dot(delta, north))
    }

    /// Compatibility convenience for cosmetic call sites. Placement and saved
    /// coordinates must use `checkedENUOffset` and handle nil explicitly.
    static func enuOffset(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> SIMD2<Double> {
        checkedENUOffset(from: origin, to: target) ?? .zero
    }

    /// Clockwise from true north. Local bearings share the ENU tangent frame;
    /// distant cosmetic bearings use a great-circle direction.
    static func checkedBearing(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> Double? {
        guard isValid(origin), isValid(target) else { return nil }
        if let offset = checkedENUOffset(from: origin, to: target) {
            return normalizedDegrees(atan2(offset.x, offset.y) * 180 / .pi)
        }
        let lat1 = origin.latitude * .pi / 180
        let lat2 = target.latitude * .pi / 180
        let deltaLon = (target.longitude - origin.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return normalizedDegrees(atan2(y, x) * 180 / .pi)
    }

    static func bearing(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> Double {
        checkedBearing(from: origin, to: target) ?? 0
    }

    /// Project a horizontal tangent displacement onto the WGS84 ellipsoid.
    /// Invalid coordinates, negative distances, and distances beyond 5 km fail.
    static func checkedCoordinate(
        from origin: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D? {
        guard isValid(origin), bearingDegrees.isFinite, distanceMeters.isFinite,
              (0...maxSupportedOffsetMeters).contains(distanceMeters) else { return nil }
        let angle = bearingDegrees * .pi / 180
        let (east, north) = axes(at: origin)
        let tangentPoint = ecef(origin)
            + distanceMeters * sin(angle) * east
            + distanceMeters * cos(angle) * north
        let scale = 1 / sqrt(
            (tangentPoint.x * tangentPoint.x + tangentPoint.y * tangentPoint.y) / (a * a)
                + tangentPoint.z * tangentPoint.z / (b * b)
        )
        let surface = tangentPoint * scale
        let horizontal = hypot(surface.x, surface.y)
        let longitude = atan2(surface.y, surface.x)
        var latitude = atan2(surface.z, horizontal * (1 - e2))
        for _ in 0..<8 {
            let sinLat = sin(latitude)
            let normalRadius = a / sqrt(1 - e2 * sinLat * sinLat)
            latitude = atan2(surface.z + e2 * normalRadius * sinLat, horizontal)
        }
        let result = CLLocationCoordinate2D(
            latitude: latitude * 180 / .pi,
            longitude: longitude * 180 / .pi
        )
        return isValid(result) ? result : nil
    }

    /// Compatibility convenience. Persisted coordinates should use the checked API.
    static func coordinate(
        from origin: CLLocationCoordinate2D,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        checkedCoordinate(
            from: origin, bearingDegrees: bearingDegrees, distanceMeters: distanceMeters
        ) ?? (isValid(origin) ? origin : CLLocationCoordinate2D(latitude: 0, longitude: 0))
    }

    /// AR horizontal axes are (+X east-like, -Z north-like). Heading correction
    /// is true bearing minus AR bearing, positive clockwise. Drift comparisons
    /// must use the correction captured with their camera-position basis.
    static func arHorizontal(fromENU enu: SIMD2<Double>, headingCorrection: Double) -> SIMD2<Double>? {
        guard enu.x.isFinite, enu.y.isFinite, headingCorrection.isFinite else { return nil }
        let c = cos(headingCorrection), s = sin(headingCorrection)
        return SIMD2(enu.x * c - enu.y * s, enu.x * s + enu.y * c)
    }

    static func enu(fromARHorizontal ar: SIMD2<Double>, headingCorrection: Double) -> SIMD2<Double>? {
        guard ar.x.isFinite, ar.y.isFinite, headingCorrection.isFinite else { return nil }
        let c = cos(headingCorrection), s = sin(headingCorrection)
        return SIMD2(ar.x * c + ar.y * s, -ar.x * s + ar.y * c)
    }

    static func driftMeters(
        gpsENU: SIMD2<Double>,
        arHorizontal: SIMD2<Double>,
        basisHeadingCorrection: Double
    ) -> Double? {
        guard let arENU = enu(fromARHorizontal: arHorizontal,
                              headingCorrection: basisHeadingCorrection),
              gpsENU.x.isFinite, gpsENU.y.isFinite else { return nil }
        return simd_length(gpsENU - arENU)
    }

    /// Legacy single-fix prediction. Transit should use LocationService's
    /// timestamped estimator so exhausted prediction is explicit in the UI.
    static func predicted(from location: CLLocation, at date: Date) -> CLLocationCoordinate2D {
        let elapsed = date.timeIntervalSince(location.timestamp)
        guard isValid(location.coordinate), elapsed.isFinite, elapsed > 0,
              location.speed.isFinite, location.speed > 2,
              location.course.isFinite, (0..<360).contains(location.course) else {
            return isValid(location.coordinate)
                ? location.coordinate : CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        return coordinate(from: location.coordinate, bearingDegrees: location.course,
                          distanceMeters: location.speed * min(elapsed, 8))
    }

    static func compassPoint(for bearing: Double) -> String {
        guard bearing.isFinite else { return "?" }
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((normalizedDegrees(bearing) + 22.5)
            .truncatingRemainder(dividingBy: 360) / 45)
        return points[index]
    }

    static func distanceLabel(_ meters: CLLocationDistance) -> String {
        guard meters.isFinite, meters >= 0 else { return "?" }
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1_000)
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let normalized = wrapped < 0 ? wrapped + 360 : wrapped
        // Floating-point atan2 can return -ε for exact north; its positive
        // modulo is 360-ε even though the canonical bearing is zero.
        return normalized >= 360 - 1e-10 ? 0 : normalized
    }

    private static func ecef(_ coordinate: CLLocationCoordinate2D) -> SIMD3<Double> {
        let lat = coordinate.latitude * .pi / 180
        let lon = coordinate.longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let normalRadius = a / sqrt(1 - e2 * sinLat * sinLat)
        return SIMD3(
            normalRadius * cosLat * cos(lon),
            normalRadius * cosLat * sin(lon),
            normalRadius * (1 - e2) * sinLat
        )
    }

    private static func axes(
        at coordinate: CLLocationCoordinate2D
    ) -> (east: SIMD3<Double>, north: SIMD3<Double>) {
        let lat = coordinate.latitude * .pi / 180
        let lon = coordinate.longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)
        return (
            SIMD3(-sinLon, cosLon, 0),
            SIMD3(-sinLat * cosLon, -sinLat * sinLon, cosLat)
        )
    }
}
