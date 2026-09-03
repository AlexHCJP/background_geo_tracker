import CoreLocation
import CoreMotion
import Foundation

/// The two things that wake a collector whose GPS is off: the motion
/// coprocessor, which answers within metres, and a region around the anchor,
/// which answers at roughly 200 m. Both are armed; whichever fires first wins.
///
/// Region monitoring runs on the collector's own `CLLocationManager` rather
/// than a second one: the delegate is what receives the exit, and two managers
/// would mean two delegates answering for one session.
final class MotionDetector {
    /// Called with the detector that fired — `"activity"` or `"geofence"`.
    /// Always on the main queue, because both sources deliver there.
    var onMovement: ((String) -> Void)?

    static let anchorId = "attractor_geo_anchor"

    private let motion = CMMotionActivityManager()
    private var watchingActivity = false

    /// Whether this device has a motion coprocessor at all. An iPad without
    /// one is not a user who refused anything.
    private var available: Bool { CMMotionActivityManager.isActivityAvailable() }

    /// Triggers the system prompt, once, at session start.
    ///
    /// CoreMotion has no request API: the dialog appears on the first call to
    /// `startActivityUpdates`, so asking means starting and immediately
    /// stopping. Doing it at session start rather than at the first stop means
    /// the user is asked while they are looking at the app, not five minutes
    /// after they put it down.
    func primePermission() {
        guard available,
              CMMotionActivityManager.authorizationStatus() == .notDetermined
        else { return }
        motion.startActivityUpdates(to: .main) { _ in }
        motion.stopActivityUpdates()
    }

    /// Arms both detectors around the anchor. Returns what actually got armed,
    /// for the log: a session that wakes late is otherwise indistinguishable
    /// from one that never armed anything at all.
    func arm(
        manager: CLLocationManager,
        lat: Double,
        lon: Double,
        radiusMeters: Double
    ) -> String {
        var armed: [String] = []

        // Region monitoring needs `Always`, which is also the only
        // authorization the state machine runs under — see `GeoTracker`.
        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                radius: min(radiusMeters, manager.maximumRegionMonitoringDistance),
                identifier: Self.anchorId
            )
            // Exit only. The device is inside by construction, and an entry
            // notification would wake the collector that was just put to sleep.
            region.notifyOnEntry = false
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            armed.append("geofence")
        }

        if available, CMMotionActivityManager.authorizationStatus() == .authorized {
            motion.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity, let self else { return }
                // `stationary` is the state we are already in, and a low
                // confidence reading is noise — waking on either would undo the
                // stop within seconds and cost more battery than never
                // stopping at all.
                guard !activity.stationary,
                      activity.walking || activity.running
                        || activity.cycling || activity.automotive,
                      activity.confidence != .low
                else { return }
                self.onMovement?("activity")
            }
            watchingActivity = true
            armed.append("activity")
        }

        return armed.joined(separator: "+")
    }

    /// Takes both down. Safe to call when nothing was armed.
    func disarm(manager: CLLocationManager) {
        if watchingActivity {
            motion.stopActivityUpdates()
            watchingActivity = false
        }
        for region in manager.monitoredRegions
        where region.identifier == Self.anchorId {
            manager.stopMonitoring(for: region)
        }
    }

    /// The wire name, matching Android's `GeoStatus.motionPermissionName`.
    ///
    /// `notDetermined` reports as `denied` on purpose: there is no detector
    /// running yet, and `unavailable` would tell the app that asking is
    /// pointless — the opposite of the truth.
    func permissionName() -> String {
        guard available else { return "unavailable" }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return "granted"
        case .denied, .restricted, .notDetermined: return "denied"
        @unknown default: return "unavailable"
        }
    }
}
