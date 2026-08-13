import Foundation

/// The launch hook. The one thing in this package a host app calls itself.
///
/// Everything else here is reached through the Flutter plugin. This cannot be:
/// the whole point of it is the launch where no Flutter engine exists.
///
/// iOS relaunches the app in the background when a significant location change
/// arrives after the process died — a reboot, an eviction, a swipe away — and
/// hands that launch to `UIApplicationDelegate` and nothing else. In a
/// scene-based app the storyboard is instantiated only when a *UI* scene
/// connects, and a background launch connects none; the implicit
/// `FlutterViewController` is what triggers plugin registration, so on that
/// path no plugin is ever registered. Without this call nothing then creates a
/// `CLLocationManager`, the session that was running when the phone went off
/// stays dead, and the last point the backend has is the one from the moment
/// the device powered down — until somebody opens the app by hand.
///
/// One line in the host's `AppDelegate`:
///
/// ```swift
/// override func application(
///   _ application: UIApplication,
///   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
/// ) -> Bool {
///   AttractorGeoLaunch.resumeIfTracking()
///   return super.application(application, didFinishLaunchingWithOptions: launchOptions)
/// }
/// ```
///
/// Safe on every launch, foreground or background, and cheap on the ones that
/// have nothing to resume: it reads one `UserDefaults` key and returns.
public enum AttractorGeoLaunch {
    /// Picks a session back up if one was running when the process died.
    ///
    /// Does nothing otherwise — a user who switched sharing off, or signed
    /// out, gets no location manager and no upload timer out of this.
    public static func resumeIfTracking() {
        guard GeoConfigStore().isTracking else { return }
        wireUploader()
        GeoTracker.shared.resumeIfTracking()
        Uploader.shared.startPeriodicDrain()
    }

    /// Tells the uploader about each new point, so a batch that is already
    /// full does not wait out the rest of the drain interval.
    ///
    /// Lives here rather than at either call site because both ways of
    /// bringing the native stack up — the plugin registering, and the launch
    /// hook above — need it, and a version that only one of them performs is
    /// the kind of difference that is invisible until a phone is in a pocket.
    static func wireUploader() {
        GeoTracker.shared.onQueueGrew = {
            Uploader.shared.drainIfNeeded(force: false)
        }
    }
}
