import CoreLocation
import Foundation

/// Publishes the device's GPS fix and true-north heading for the map and the AR engine.
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
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
        guard let latest = locations.last else { return }
        DispatchQueue.main.async { self.location = latest }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            // trueHeading is negative until a location fix exists; fall back to
            // magnetic for cosmetic consumers (map arrow, demo bearing) but FLAG
            // it, so the AR heading estimator can refuse or re-sync (MATH-3).
            let isTrue = newHeading.trueHeading >= 0
            self.headingDegrees = isTrue ? newHeading.trueHeading : newHeading.magneticHeading
            self.headingIsTrueNorth = isTrue
            self.headingAccuracy = newHeading.headingAccuracy
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.authorization = manager.authorizationStatus }
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. kCLErrorLocationUnknown) resolve on their own.
    }
}
