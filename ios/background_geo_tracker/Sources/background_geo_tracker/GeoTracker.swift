import CoreLocation
import Foundation

/// The collector. Keeps standard location updates running in the background,
/// and holds significant-location-change as the anchor that lets iOS relaunch
/// the app after it is evicted or swiped away.
final class GeoTracker: NSObject, CLLocationManagerDelegate {
    static let shared = GeoTracker()

    private let manager = CLLocationManager()
    private let config = GeoConfigStore()
    private var queue: PointQueue? { PointQueue.shared }

    private(set) var isRunning = false

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

    @discardableResult
    func start() -> Bool {
        guard config.isConfigured,
              !config.sessionId.isEmpty,
              authorizationStatus == .authorizedAlways,
              locationServicesEnabled()
        else {
            isRunning = false
            emitStatus()
            return false
        }
        config.isTracking = true
        manager.distanceFilter = CLLocationDistance(config.distanceFilterMeters)
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
        manager.startUpdatingLocation()
        isRunning = true
        emitStatus()
        return true
    }

    func stop() {
        config.isTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
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
            "collector_running": isRunning,
            "permission": permissionName(),
            "auth_failed": config.authFailed,
            "queued_points": queue?.count() ?? 0,
            "location_services_enabled": locationServicesEnabled(),
            // What the uploader would actually POST to, and how it last got
            // on. Between them these turn "the queue is not draining" from a
            // question into an answer — see `GeoTrackingStatus`.
            "upload_url": config.url,
            "last_upload": config.lastUpload,
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
            isRunning = false
        case .authorizedAlways where config.isTracking:
            start()
        case .authorizedWhenInUse:
            // Downgraded mid-session. Both of these need Always, and leaving
            // them set from the session that had it keeps updates running in
            // the background on When In Use — which is exactly when iOS shows
            // the blue bar and will not let us hide it.
            manager.allowsBackgroundLocationUpdates = false
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
            isRunning = false
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
        let row = GeoPointRow.from(location, sessionId: config.sessionId)

        queue?.enqueue(
            row,
            maxPoints: config.queueMaxPoints,
            maxAgeDays: config.queueMaxAgeDays
        )
        GeoEventBus.emitPoint(PointJson.encodeOne(row))
        onQueueGrew?()
    }

    // MARK: - Reading

    /// A cached fix younger than this is handed back as it is. Asking
    /// CoreLocation for a fresh one costs seconds the caller is asking this
    /// method to avoid, and a fix a minute old is the same room.
    private static let cacheMaxAge: TimeInterval = 60

    /// The position now, for a caller that cannot wait for the session's next
    /// point — which, behind a distance filter, may be a long way off.
    ///
    /// Neither queued nor pushed onto the points stream: this is a read, and a
    /// track that grew every time a screen asked where it was would no longer
    /// be a record of where the device went.
    ///
    /// Falls back to a stale cached fix when the fresh one does not arrive in
    /// time. Somewhere the reader was is worth more to a map than nothing, and
    /// the point carries its own timestamp for a caller that disagrees.
    func currentPosition(
        timeout: TimeInterval,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            // Deliberately does not prompt: a screen asking where it is must
            // not be what puts a permission dialog in front of the user.
            completion(nil)
            return
        }

        let cached = manager.location
        if let cached,
           -cached.timestamp.timeIntervalSinceNow <= Self.cacheMaxAge {
            completion(
                PointJson.encodeOne(
                    GeoPointRow.from(cached, sessionId: config.sessionId)
                )
            )
            return
        }

        OneShotLocation.request(timeout: timeout) { fresh in
            guard let location = fresh ?? cached else {
                completion(nil)
                return
            }
            completion(
                PointJson.encodeOne(
                    GeoPointRow.from(location, sessionId: self.config.sessionId)
                )
            )
        }
    }

    private func emitStatus() {
        GeoEventBus.emitStatus(statusMap())
    }
}
