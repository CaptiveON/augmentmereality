import CoreLocation
import Foundation
import simd

/// Core Location may replay cached fixes when an update stream starts. Only
/// timestamped, geographically valid measurements enter the public location
/// stream. A previously accepted fix can remain for warm-session UI state, but
/// `currentLocation` and `transitEstimate` report its age at use time.
enum LocationFixPolicy {
    static let maximumArrivalAge: TimeInterval = 30
    static let futureTolerance: TimeInterval = 2
    static let maximumHorizontalAccuracy = 500.0

    static func accepts(_ fix: CLLocation, at now: Date, newerThan last: Date?) -> Bool {
        if let last, fix.timestamp <= last { return false }
        let age = now.timeIntervalSince(fix.timestamp)
        return GeoMath.isValid(fix.coordinate)
            && fix.horizontalAccuracy.isFinite
            && fix.horizontalAccuracy > 0
            && fix.horizontalAccuracy <= maximumHorizontalAccuracy
            && age.isFinite && (-futureTolerance...maximumArrivalAge).contains(age)
    }
}

struct HeadingSample: Sendable {
    enum NorthReference: Sendable { case trueNorth, magneticNorth }

    let degrees: Double
    let timestamp: Date
    let accuracyDegrees: Double
    let reference: NorthReference

    func isCurrent(at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return degrees.isFinite && (0..<360).contains(degrees)
            && accuracyDegrees.isFinite && (0...45).contains(accuracyDegrees)
            && age.isFinite && (-2...2).contains(age)
    }
}

/// Copy delegate data into sendable values before hopping to the publication
/// queue. Core Location objects themselves are not safe cross-actor captures.
private struct LocationFixSnapshot: Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let course: Double
    let speed: Double
    let timestamp: Date

    init(_ fix: CLLocation) {
        latitude = fix.coordinate.latitude
        longitude = fix.coordinate.longitude
        altitude = fix.altitude
        horizontalAccuracy = fix.horizontalAccuracy
        verticalAccuracy = fix.verticalAccuracy
        course = fix.course
        speed = fix.speed
        timestamp = fix.timestamp
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

/// Timestamped constant-velocity filter for transit. Rendering only asks for a
/// prediction; it never treats a render callback as another measurement. The
/// caller must give `.degraded`/`.reacquiring` a visibly degraded presentation.
struct TransitLocationEstimator {
    enum Quality { case tracking, reacquiring, degraded }

    struct Estimate {
        let coordinate: CLLocationCoordinate2D
        let horizontalUncertainty: Double
        let measurementAge: TimeInterval
        let quality: Quality
        let speedMetersPerSecond: Double?
    }

    static let maximumPredictionAge: TimeInterval = 8
    static let maximumUncertainty = 100.0
    private static let maximumSpeed = 80.0

    private struct State {
        var coordinate: CLLocationCoordinate2D
        var velocity: SIMD2<Double>
        var uncertainty: Double
        var timestamp: Date
    }

    private var state: State?
    private var lastInputAt: Date?
    private var pendingOutlier: CLLocation?
    private var reacquiringUntil: Date?
    private var reacquiringNeedsSecondFix = false

    mutating func reset() {
        state = nil
        lastInputAt = nil
        pendingOutlier = nil
        reacquiringUntil = nil
        reacquiringNeedsSecondFix = false
    }

    @discardableResult
    mutating func ingest(_ fix: CLLocation, at now: Date) -> Bool {
        guard LocationFixPolicy.accepts(fix, at: now, newerThan: lastInputAt) else {
            return false
        }
        lastInputAt = fix.timestamp
        guard let old = state else {
            state = seeded(from: fix)
            return true
        }

        let elapsed = fix.timestamp.timeIntervalSince(old.timestamp)
        guard elapsed > 0 else { return false }
        // Once open-loop prediction expired, its residual is no longer a sound
        // filter innovation. Reacquire from fresh evidence while presentation
        // remains hidden until a second fix corroborates the new trajectory.
        if elapsed > Self.maximumPredictionAge {
            state = seeded(from: fix)
            pendingOutlier = nil
            reacquiringUntil = now.addingTimeInterval(2)
            reacquiringNeedsSecondFix = true
            return true
        }

        let predicted = propagated(old, by: min(elapsed, Self.maximumPredictionAge))
        guard let residual = GeoMath.checkedENUOffset(
            from: predicted.coordinate, to: fix.coordinate
        ) else {
            return handleOutlier(fix, at: now)
        }
        let residualLength = simd_length(residual)
        let gate = max(35, 5 * (predicted.uncertainty + fix.horizontalAccuracy))
        if residualLength > gate {
            return handleOutlier(fix, at: now)
        }
        pendingOutlier = nil
        reacquiringNeedsSecondFix = false

        let measurementVariance = pow(max(fix.horizontalAccuracy, 3), 2)
        let predictedVariance = pow(predicted.uncertainty, 2)
        let gain = min(0.35, max(0.08,
            predictedVariance / (predictedVariance + measurementVariance)
        ))
        // A badly understated accuracy must not move all content many metres on
        // one callback. Velocity and future fixes absorb the residual gradually.
        let correction = residual * min(gain, 15 / max(residualLength, 0.001))
        guard let coordinate = translated(predicted.coordinate, by: correction) else {
            return false
        }
        var velocity = predicted.velocity + residual * (0.12 / max(elapsed, 0.5))
        if let reported = reportedVelocity(fix) {
            velocity = velocity * 0.8 + reported * 0.2
        } else if fix.speed.isFinite && (0...0.6).contains(fix.speed) {
            velocity *= 0.8
        }
        velocity = bounded(velocity, maximum: Self.maximumSpeed)
        let unappliedResidual = max(0, residualLength - simd_length(correction))
        state = State(
            coordinate: coordinate,
            velocity: velocity,
            uncertainty: max(3, hypot(
                sqrt((1 - gain) * predictedVariance), unappliedResidual
            )),
            timestamp: fix.timestamp
        )
        return true
    }

    func estimate(at now: Date) -> Estimate? {
        guard let state else { return nil }
        let age = now.timeIntervalSince(state.timestamp)
        guard age.isFinite, age >= -LocationFixPolicy.futureTolerance else { return nil }
        let predictionAge = min(max(age, 0), Self.maximumPredictionAge)
        let predicted = propagated(state, by: predictionAge)
        let uncertainty = state.uncertainty + 2 * max(age, 0)
            + 0.25 * pow(max(age, 0), 2)
        let quality: Quality
        if age > Self.maximumPredictionAge || uncertainty > Self.maximumUncertainty {
            quality = .degraded
        } else if reacquiringNeedsSecondFix
            || (reacquiringUntil.map { now < $0 } ?? false) {
            quality = .reacquiring
        } else {
            quality = .tracking
        }
        let speed = simd_length(state.velocity)
        return Estimate(
            coordinate: predicted.coordinate,
            horizontalUncertainty: uncertainty,
            measurementAge: max(age, 0),
            quality: quality,
            speedMetersPerSecond: speed.isFinite ? speed : nil
        )
    }

    private mutating func handleOutlier(_ fix: CLLocation, at now: Date) -> Bool {
        if let candidate = pendingOutlier,
           fix.timestamp.timeIntervalSince(candidate.timestamp) <= 10,
           let separation = GeoMath.checkedENUOffset(
            from: candidate.coordinate, to: fix.coordinate
           ), simd_length(separation) <= max(30, 2 * fix.horizontalAccuracy) {
            state = seeded(from: fix)
            pendingOutlier = nil
            reacquiringUntil = now.addingTimeInterval(2)
            reacquiringNeedsSecondFix = false
            return true
        }
        pendingOutlier = fix
        return false
    }

    private func seeded(from fix: CLLocation) -> State {
        State(
            coordinate: fix.coordinate,
            velocity: reportedVelocity(fix) ?? .zero,
            uncertainty: max(3, fix.horizontalAccuracy),
            timestamp: fix.timestamp
        )
    }

    private func propagated(_ state: State, by seconds: TimeInterval) -> State {
        let displacement = bounded(state.velocity * max(seconds, 0),
                                   maximum: GeoMath.maxSupportedOffsetMeters)
        return State(
            coordinate: translated(state.coordinate, by: displacement) ?? state.coordinate,
            velocity: state.velocity,
            uncertainty: state.uncertainty + 2 * seconds + 0.25 * seconds * seconds,
            timestamp: state.timestamp.addingTimeInterval(seconds)
        )
    }

    private func translated(
        _ coordinate: CLLocationCoordinate2D, by offset: SIMD2<Double>
    ) -> CLLocationCoordinate2D? {
        let distance = simd_length(offset)
        return GeoMath.checkedCoordinate(
            from: coordinate,
            bearingDegrees: atan2(offset.x, offset.y) * 180 / .pi,
            distanceMeters: distance
        )
    }

    private func reportedVelocity(_ fix: CLLocation) -> SIMD2<Double>? {
        guard fix.speed.isFinite, (0...Self.maximumSpeed).contains(fix.speed),
              fix.course.isFinite, (0..<360).contains(fix.course) else { return nil }
        let course = fix.course * .pi / 180
        return SIMD2(fix.speed * sin(course), fix.speed * cos(course))
    }

    private func bounded(_ vector: SIMD2<Double>, maximum: Double) -> SIMD2<Double> {
        let length = simd_length(vector)
        guard length.isFinite else { return .zero }
        return length > maximum ? vector * (maximum / length) : vector
    }
}

/// Publishes the device's GPS fix and true-north heading for the map and the AR engine.
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var headingSample: HeadingSample?
    /// Degrees clockwise from north, nil until the compass reports. TRUE north
    /// when `headingIsTrueNorth`; otherwise magnetic (no declination applied).
    @Published private(set) var headingDegrees: Double?
    /// Whether `headingDegrees` is referenced to true north. Core Location can
    /// only supply true heading once it has a location fix; before that it
    /// reports magnetic, which differs by the local declination (±15° in major
    /// US cities). World alignment must not consume magnetic-only samples as
    /// truth (counsel MATH-3).
    @Published private(set) var headingIsTrueNorth = false
    /// Compass accuracy in degrees; large/negative values mean "needs calibration".
    /// Magnetometer-only: carries NO information about declination error.
    @Published private(set) var headingAccuracy: Double?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var transitEstimator = TransitLocationEstimator()

    func currentLocation(at now: Date = Date()) -> CLLocation? {
        guard let location,
              LocationFixPolicy.accepts(location, at: now, newerThan: nil) else { return nil }
        return location
    }

    func currentHeading(at now: Date = Date()) -> HeadingSample? {
        guard let headingSample, headingSample.isCurrent(at: now) else { return nil }
        return headingSample
    }

    func transitEstimate(at now: Date = Date()) -> TransitLocationEstimator.Estimate? {
        transitEstimator.estimate(at: now)
    }

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.headingFilter = 2
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let snapshots = locations.map(LocationFixSnapshot.init)
        DispatchQueue.main.async {
            for snapshot in snapshots {
                let fix = snapshot.location
                let now = Date()
                guard LocationFixPolicy.accepts(
                    fix, at: now, newerThan: self.location?.timestamp
                ) else { continue }
                self.location = fix
                self.transitEstimator.ingest(fix, at: now)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // CLHeading is not Sendable; extract the timestamped primitive sample
        // before scheduling publication on the main queue.
        let isTrue = newHeading.trueHeading >= 0
        let sample = HeadingSample(
            degrees: isTrue ? newHeading.trueHeading : newHeading.magneticHeading,
            timestamp: newHeading.timestamp,
            accuracyDegrees: newHeading.headingAccuracy,
            reference: isTrue ? .trueNorth : .magneticNorth
        )
        DispatchQueue.main.async {
            // trueHeading is negative until a location fix exists; fall back to
            // magnetic for cosmetic consumers (map arrow, demo bearing) but FLAG
            // it, so the AR heading estimator can refuse or re-sync (MATH-3).
            guard sample.isCurrent(at: Date()) else { return }
            if let previous = self.headingSample,
               sample.timestamp <= previous.timestamp { return }
            self.headingSample = sample
            self.headingDegrees = sample.degrees
            self.headingIsTrueNorth = isTrue
            self.headingAccuracy = sample.accuracyDegrees
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { self.authorization = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. kCLErrorLocationUnknown) resolve on their own.
    }
}
