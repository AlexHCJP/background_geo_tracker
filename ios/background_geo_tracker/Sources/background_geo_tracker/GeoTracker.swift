import CoreLocation
import Foundation
import UIKit

/// The collector. Keeps standard location updates running in the background,
/// and holds significant-location-change as the anchor that lets iOS relaunch
/// the app after it is evicted or swiped away.
final class GeoTracker: NSObject, CLLocationManagerDelegate {
    static let shared = GeoTracker()

    private let manager = CLLocationManager()
    private let config = GeoConfigStore()
    private var queue: PointQueue? { PointQueue.shared }

    /// Called after each enqueue so the uploader can decide to drain.
    var onQueueGrew: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .otherNavigation
        // Without this iOS decides on its own when to pause updates, and the
        // track quietly stops.
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// The app supports iOS 13, where the status is only available as a class
    /// method. The instance property arrived in iOS 14.
    private var authorizationStatus: CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return manager.authorizationStatus
        }
        return CLLocationManager.authorizationStatus()
    }

    func start() {
        config.isTracking = true
        manager.distanceFilter = CLLocationDistance(config.distanceFilterMeters)
        if authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            // The blue bar is optional under `Always` — this is its default,
            // spelled out because setting it to true is what we did before and
            // it is an easy thing to reintroduce by accident.
            //
            // It is NOT optional under `When In Use`: iOS shows it for the
            // whole time background updates run on that authorization, and no
            // property here can suppress it. So a blue bar after this line is
            // a symptom, not a setting — it means the session is running on
            // `When In Use`.
            manager.showsBackgroundLocationIndicator = false
            // The relaunch anchor. Standard updates alone do not bring the app
            // back after the user swipes it away.
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startUpdatingLocation()
        emitStatus()
    }

    func stop() {
        config.isTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        emitStatus()
    }

    /// Called on launch — including a relaunch triggered by location — so a
    /// session that was running before the process died picks straight back up.
    func resumeIfTracking() {
        guard config.isTracking else { return }
        start()
    }

    func permissionName() -> String {
        switch authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when_in_use"
        case .denied, .restricted: return "permanently_denied"
        case .notDetermined: return "denied"
        @unknown default: return "denied"
        }
    }

    /// Escalates exactly one step. Asking for `Always` before `WhenInUse` is
    /// granted gets shown as "allow once", with no upgrade path afterwards.
    func requestNextPermission() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func locationServicesEnabled() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }

    func statusMap() -> [String: Any] {
        [
            "is_tracking": config.isTracking,
            "permission": permissionName(),
            "auth_failed": config.authFailed,
            "queued_points": queue?.count() ?? 0,
            "location_services_enabled": locationServicesEnabled(),
        ]
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        for location in locations {
            record(location)
        }
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange()
    }

    /// The iOS 13 callback. On iOS 14 and later only the newer delegate method
    /// above is called, so this cannot double-fire.
    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        handleAuthorizationChange()
    }

    private func handleAuthorizationChange() {
        // Permission can be revoked from Settings mid-session. Stop collecting,
        // but leave the queue alone — what we already have still uploads.
        switch authorizationStatus {
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        case .authorizedAlways where config.isTracking:
            start()
        case .authorizedWhenInUse:
            // Downgraded mid-session. Both of these need Always, and leaving
            // them set from the session that had it keeps updates running in
            // the background on When In Use — which is exactly when iOS shows
            // the blue bar and will not let us hide it.
            manager.allowsBackgroundLocationUpdates = false
            manager.stopMonitoringSignificantLocationChanges()
        default:
            break
        }
        emitStatus()
    }

    func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        // Failing to get a fix is normal indoors; the queue and the session
        // both survive it, so there is nothing to do but report.
        emitStatus()
    }

    // MARK: - Recording

    private func record(_ location: CLLocation) {
        let row = GeoPointRow(
            id: UUID().uuidString,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            // CLLocation reports -1 when it has nothing, which must not be
            // sent on as a real reading.
            speed: location.speed >= 0 ? location.speed : nil,
            heading: location.course >= 0 ? location.course : nil,
            recordedAtMillis: Int64(
                location.timestamp.timeIntervalSince1970 * 1000
            ),
            isMock: isSimulated(location),
            batteryLevel: batteryLevel()
        )

        queue?.enqueue(
            row,
            maxPoints: config.queueMaxPoints,
            maxAgeDays: config.queueMaxAgeDays
        )
        GeoEventBus.emitPoint(PointJson.encodeOne(row))
        onQueueGrew?()
    }

    private func isSimulated(_ location: CLLocation) -> Bool {
        if #available(iOS 15.0, *) {
            return location.sourceInformation?.isSimulatedBySoftware ?? false
        }
        // No API below iOS 15 — reported as not simulated rather than guessed.
        return false
    }

    /// Fraction from 0.0 to 1.0, as the wire format requires.
    private func batteryLevel() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }

    private func emitStatus() {
        GeoEventBus.emitStatus(statusMap())
    }
}
