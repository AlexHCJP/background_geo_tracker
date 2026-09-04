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

    private(set) var isRunning = false

    /// Called after each enqueue so the uploader can decide to drain.
    var onQueueGrew: (() -> Void)?

    /// Rebuilt on every `start`, so a config change between sessions takes
    /// effect and no state crosses from the previous one.
    private var filter = LocationFilter(
        accuracyThresholdMeters: 100,
        minDisplacementMeters: 1,
        maxImpliedSpeedMps: 60,
        kalmanProcessNoiseMps: 3
    )

    private let detector = MotionDetector()

    /// Rebuilt on every `start`, like the filter: a config change between
    /// sessions must take effect, and no anchor may cross from the last one.
    private var policy = MotionPolicy(
        stopTimeoutSeconds: 300,
        stationaryRadiusMeters: 150,
        elasticityMultiplier: 1,
        baseDistanceFilterMeters: 20
    )

    /// Whether the state machine may run at all. Region monitoring needs
    /// `Always`, so under `When In Use` a switched-off GPS is a session nobody
    /// can wake. Elasticity is not gated on this.
    private var stopDetectionAllowed: Bool {
        authorizationStatus == .authorizedAlways
    }

    private override init() {
        super.init()
        manager.delegate = self
        detector.onMovement = { [weak self] source in self?.wake(source) }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .otherNavigation
        // Without this iOS decides on its own when to pause updates, and the
        // track quietly stops.
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Translates a configured filter into what CoreLocation understands.
    ///
    /// Zero is the trap: `kCLDistanceFilterNone` is `-1`, and a
    /// `distanceFilter` of `0` is not "report everything" — it is a value
    /// CoreLocation does not define, and in practice the delegate goes quiet.
    /// An app asking for no filter has to be given the constant.
    private static func distanceFilter(_ meters: Double) -> CLLocationDistance {
        meters <= 0 ? kCLDistanceFilterNone : CLLocationDistance(meters)
    }

    /// The app supports iOS 13, where the status is only available as a class
    /// method. The instance property arrived in iOS 14.
    private var authorizationStatus: CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return manager.authorizationStatus
        }
        return CLLocationManager.authorizationStatus()
    }

    /// Whether the OS is handing over real coordinates or a rough area.
    ///
    /// From iOS 14 a user can grant location while withholding precision, and
    /// nothing about that reads as a refusal: the authorization is granted,
    /// fixes keep arriving, and each one is placed somewhere within a few
    /// kilometres. Before iOS 14 there was no such setting, so there is
    /// nothing to withhold and this is true.
    var preciseLocation: Bool {
        if #available(iOS 14.0, *) {
            return manager.accuracyAuthorization == .fullAccuracy
        }
        return true
    }

    /// The key iOS looks up in `NSLocationTemporaryUsageDescriptionDictionary`
    /// to find the sentence it shows the user. A host without this key in its
    /// Info.plist gets no prompt at all — see the README.
    private static let temporaryFullAccuracyPurposeKey = "TrackingUsage"

    /// Asks, once per session, for precision the user withheld.
    ///
    /// Temporary by construction: iOS grants it until the app is next
    /// restarted, and there is no permanent upgrade to ask for. Silent when
    /// the user says no — refusing is an answer, and a session on approximate
    /// coordinates is still worth more than no session.
    private func requestFullAccuracyIfReduced() {
        guard #available(iOS 14.0, *), !preciseLocation else { return }
        manager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: Self.temporaryFullAccuracyPurposeKey
        )
    }

    /// Whether the OS will give this session anything at all.
    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways:
            return true
        default:
            return false
        }
    }

    /// Opens a session, or refuses because the OS would give it nothing.
    ///
    /// Returns false rather than starting a session that cannot collect. It
    /// used to set `isTracking` before looking at the authorization, which
    /// made a refused permission indistinguishable from a healthy session
    /// from the outside — the status said `is_tracking: true` for ever after,
    /// and `GeoAutoSession` takes that as its cue to stop evaluating, so the
    /// permission was never asked for again. Android has always refused here;
    /// this is that behaviour.
    @discardableResult
    func start() -> Bool {
        guard isAuthorized else {
            isRunning = false
            emitStatus()
            return false
        }

        guard config.isConfigured, !config.sessionId.isEmpty else {
            isRunning = false
            emitStatus()
            return false
        }

        guard locationServicesEnabled() else {
            isRunning = false
            emitStatus()
            return false
        }

        config.isTracking = true
        manager.distanceFilter = Self.distanceFilter(
            Double(config.distanceFilterMeters)
        )

        // Reopening is not resuming: the floor below is about the spacing of a
        // session's own points, and holding a fix from the last one against
        // the first of this one would swallow it. The same goes for the
        // filter, whose smoother would otherwise drag the first fix of this
        // session toward wherever the last one ended.
        lastRecordedAt = nil
        filter = LocationFilter(
            accuracyThresholdMeters: config.filterAccuracyThresholdMeters,
            minDisplacementMeters: config.filterMinDisplacementMeters,
            maxImpliedSpeedMps: config.filterMaxImpliedSpeedMps,
            kalmanProcessNoiseMps: config.filterKalmanProcessNoiseMps
        )
        policy = MotionPolicy(
            stopTimeoutSeconds: config.motionStopTimeoutSeconds,
            stationaryRadiusMeters: config.motionStationaryRadiusMeters,
            elasticityMultiplier: config.motionElasticityMultiplier,
            baseDistanceFilterMeters: Double(config.distanceFilterMeters)
        )
        config.isMoving = true

        // Taken down first: `start` is also the resume path, and a session
        // coming back from a background launch may still have the last one's
        // detectors armed.
        detector.disarm(manager: manager)

        // Set under `When In Use` as well as `Always`, which is the whole
        // point of it. iOS grants background updates on either one so long as
        // the host declares the `location` background mode.
        manager.allowsBackgroundLocationUpdates = true

        if authorizationStatus == .authorizedAlways {
            // The blue bar is optional under `Always` — this is its default,
            // spelled out because setting it to true is what we did before and
            // it is an easy thing to reintroduce by accident.
            //
            // It is NOT optional under `When In Use`: iOS shows it for the
            // whole time background updates run on that authorization, and no
            // property here can suppress it.
            manager.showsBackgroundLocationIndicator = false

            // The relaunch anchor. Standard updates alone do not bring the app
            // back after the user swipes it away.
            manager.startMonitoringSignificantLocationChanges()
        }

        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "info",
            event: "session.start",
            message: "\(permissionName()) precise=\(preciseLocation) "
                + "background=\(manager.allowsBackgroundLocationUpdates)"
        )

        manager.startUpdatingLocation()
        isRunning = true

        // After `startUpdatingLocation`, so a user who grants precision sees
        // the session it was asked for begin immediately rather than after
        // the next fix, and one who refuses has already been collecting all
        // along.
        requestFullAccuracyIfReduced()

        if stopDetectionAllowed {
            detector.primePermission()
        }

        // Written at session start rather than on the answer: CoreMotion has
        // no callback for its dialog, so the state is what can be observed and
        // today's answer shows up in tomorrow's session.
        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "info",
            event: "motion.permission",
            message: detector.permissionName()
        )

        emitStatus()
        return true
    }

    func stop() {
        config.isTracking = false
        detector.disarm(manager: manager)
        config.isMoving = true
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false

        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "info",
            event: "session.stop",
            message: "asked by the app"
        )

        emitStatus()
    }

    /// Called on launch — including a relaunch triggered by location — so a
    /// session that was running before the process died picks straight back up.
    @discardableResult
    func resumeIfTracking() -> Bool {
        guard config.isTracking else { return false }
        guard config.isConfigured, !config.sessionId.isEmpty, isAuthorized,
              locationServicesEnabled()
        else {
            stop()
            return false
        }

        // The path iOS uses to bring the app up in the background after the
        // process died. No Dart call comes with it, so without this line it
        // leaves no trace at all.
        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "info",
            event: "session.resume",
            message: "launch or significant change"
        )

        return start()
    }

    /// Puts the collector to sleep: the GPS goes off, the detectors go on.
    ///
    /// Significant-location-change stays running. It is the relaunch anchor —
    /// what brings the app back after iOS evicts the process — and it costs
    /// nothing while the device is not moving.
    private func goStationary(
        anchorLat: Double,
        anchorLon: Double,
        radiusMeters: Double,
        stillSeconds: Int64
    ) {
        manager.stopUpdatingLocation()

        let armed = detector.arm(
            manager: manager,
            lat: anchorLat,
            lon: anchorLon,
            radiusMeters: radiusMeters
        )

        config.isMoving = false

        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "info",
            event: "motion.stationary",
            message: String(
                format: "anchor=%.5f,%.5f r=%.0fm still=%ds armed=%@",
                anchorLat,
                anchorLon,
                radiusMeters,
                stillSeconds,
                armed.isEmpty ? "nothing" : armed
            )
        )

        emitStatus()
    }

    /// A detector fired: the GPS comes back and the detectors stand down.
    private func wake(_ source: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        guard policy.onMovementDetected(atMillis: now) else {
            return
        }

        detector.disarm(manager: manager)
        config.isMoving = true
        manager.distanceFilter = Self.distanceFilter(
            Double(config.distanceFilterMeters)
        )
        manager.startUpdatingLocation()

        GeoLogStore.shared?.write(
            atMillis: now,
            level: "info",
            event: "motion.moving",
            message: source
        )

        emitStatus()
    }

    func permissionName() -> String {
        switch authorizationStatus {
        case .authorizedAlways:
            return "always"
        case .authorizedWhenInUse:
            return "when_in_use"
        case .denied, .restricted:
            return "permanently_denied"
        case .notDetermined:
            return "denied"
        @unknown default:
            return "denied"
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
            "upload_url": config.url,
            "last_upload": config.lastUpload,
            "precise_location": preciseLocation,
            "needs_background_rationale": false,
            "power_save_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "ignoring_battery_optimizations": true,
            "is_moving": config.isMoving,
            "motion_permission": detector.permissionName(),
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

    func locationManager(
        _ manager: CLLocationManager,
        didExitRegion region: CLRegion
    ) {
        guard region.identifier == MotionDetector.anchorId else {
            return
        }

        wake("geofence")
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
            detector.disarm(manager: manager)
            isRunning = false

        case .authorizedAlways where config.isTracking:
            start()

        case .authorizedWhenInUse:
            // Downgraded mid-session. Background updates stay on — they are
            // allowed on this authorization too, and switching them off here
            // would end the session in the background rather than continue it
            // with the blue bar showing. Significant-location-change is the
            // one that genuinely needs Always, so only it goes.
            manager.stopMonitoringSignificantLocationChanges()
            detector.disarm(manager: manager)
            config.isMoving = true

        default:
            break
        }

        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: "warning",
            event: "permission.changed",
            message: "\(permissionName()) precise=\(preciseLocation)"
        )

        emitStatus()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Failing to get a fix is normal indoors; the queue and the session
        // both survive it, so there is nothing to do but report.
        emitStatus()
    }

    // MARK: - Recording

    /// Timestamp of the last fix that made it into the queue, for the floor
    /// below. Session-scoped: `start` clears it.
    private var lastRecordedAt: Date?

    private func record(_ location: CLLocation) {
        // `minIntervalSeconds` used to be honoured on Android and nowhere
        // else: iOS wrote it to `UserDefaults`, exposed a getter, and never
        // read it, so the only thing spacing points out here was the distance
        // filter. One config meaning two things across the two platforms is
        // worse than either behaviour.
        //
        // Measured on the fix's own timestamp rather than the clock, matching
        // Android. An out-of-order fix reads as a negative interval and is
        // dropped, which is what we want from one.
        let floor = TimeInterval(config.minIntervalSeconds)

        if let last = lastRecordedAt,
           location.timestamp.timeIntervalSince(last) < floor {
            return
        }

        lastRecordedAt = location.timestamp

        // Before anything else happens to the fix: a rejected one must cost no
        // database write, no event, and no upload trigger. Single-threaded by
        // way of this delegate always arriving on the main queue.
        let verdict = filter.apply(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            recordedAtMillis: Int64(
                location.timestamp.timeIntervalSince1970 * 1000
            )
        )

        guard case let .accept(lat, lon, accuracy) = verdict else {
            if case let .reject(reason) = verdict {
                GeoLogStore.shared?.write(
                    atMillis: Int64(
                        location.timestamp.timeIntervalSince1970 * 1000
                    ),
                    level: "info",
                    event: "fix.rejected",
                    message: reason
                )
            }
            return
        }

        GeoLogStore.shared?.write(
            atMillis: Int64(
                location.timestamp.timeIntervalSince1970 * 1000
            ),
            level: "info",
            event: "fix.accepted",
            message: String(
                format: "%.5f,%.5f acc %.0f→%.0f",
                lat,
                lon,
                location.horizontalAccuracy,
                accuracy
            )
        )

        // Raw position, kept fixes only — the same inputs Android's collector
        // feeds its policy, so the two answer identically.
        let decision = policy.onFix(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            // CoreLocation reports a negative speed for "no reading", which
            // would read as motion in reverse. Zero means no information.
            speedMps: location.speed > 0 ? location.speed : 0,
            atMillis: Int64(
                location.timestamp.timeIntervalSince1970 * 1000
            )
        )

        switch decision {
        case let .stop(
            anchorLat,
            anchorLon,
            radiusMeters,
            stillSeconds
        ):
            if stopDetectionAllowed {
                // The fix that ended the session is still a real position and
                // still goes into the track below.
                goStationary(
                    anchorLat: anchorLat,
                    anchorLon: anchorLon,
                    radiusMeters: radiusMeters,
                    stillSeconds: stillSeconds
                )
            } else {
                // Under `When In Use` the machine does not run, and the policy
                // must not be left believing it does.
                _ = policy.onMovementDetected(
                    atMillis: Int64(
                        location.timestamp.timeIntervalSince1970 * 1000
                    )
                )
            }

        case let .keepGoing(
            distanceFilterMeters,
            stepped,
            stepChanged
        ):
            manager.distanceFilter = Self.distanceFilter(
                distanceFilterMeters
            )

            if stepChanged {
                // Logged on the step, not on every fix, so the line stays
                // readable.
                GeoLogStore.shared?.write(
                    atMillis: Int64(
                        location.timestamp.timeIntervalSince1970 * 1000
                    ),
                    level: "info",
                    event: "filter.elasticity",
                    message: String(
                        format: "%.1fm/s → %.0fm",
                        max(location.speed, 0),
                        stepped
                    )
                )
            }
        }

        let row = GeoPointRow.from(location)
            .movedTo(
                lat: lat,
                lon: lon,
                accuracy: accuracy
            )

        queue?.enqueue(
            row,
            maxPoints: config.queueMaxPoints,
            maxAgeDays: config.queueMaxAgeDays
        )

        GeoLogStore.shared?.write(
            atMillis: row.recordedAtMillis,
            level: "info",
            event: "queue.enqueued",
            message: "\(row.id) depth=\(queue?.count() ?? 0)"
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
    /// Neither queued nor pushed onto the points stream: this is a read, and
    /// a track that grew every time a screen asked where it was would no
    /// longer be a record of where the device went.
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
                    GeoPointRow.from(
                        cached,
                        sessionId: config.sessionId
                    )
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
                    GeoPointRow.from(
                        location,
                        sessionId: self.config.sessionId
                    )
                )
            )
        }
    }

    private func emitStatus() {
        GeoEventBus.emitStatus(statusMap())
    }
}