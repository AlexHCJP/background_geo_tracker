import CoreLocation
import Foundation

/// One fix, asked for and answered once.
///
/// Runs on a `CLLocationManager` of its own rather than the tracker's. The two
/// ways of asking share a single delegate on any one manager, so a
/// `requestLocation` on the manager that is running the session would deliver
/// its answer into the collector's `didUpdateLocations` — recording a point
/// nobody asked to record, and, on failure, reporting a session error for
/// something that was only a read. A separate manager keeps a read a read.
///
/// Answers exactly once: whichever of the fix, the failure and the timeout
/// comes first wins, and the rest are dropped.
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    /// Requests still waiting for CoreLocation.
    ///
    /// `CLLocationManager` holds its delegate weakly and nothing else holds
    /// one of these, so without this the object would be deallocated on the
    /// way out of `request` and the answer would arrive at nobody.
    private static var pending = Set<OneShotLocation>()

    private let manager = CLLocationManager()
    private var answer: ((CLLocation?) -> Void)?
    private var deadline: DispatchWorkItem?

    /// Asks for a fix, calling [completion] on the main queue with null when
    /// CoreLocation fails or takes longer than [timeout].
    ///
    /// Main queue only: `CLLocationManager` delivers to the queue its delegate
    /// was set on, and this one has to be the queue the plugin answers on.
    static func request(
        timeout: TimeInterval,
        completion: @escaping (CLLocation?) -> Void
    ) {
        let locator = OneShotLocation()
        pending.insert(locator)
        locator.begin(timeout: timeout) { location in
            pending.remove(locator)
            completion(location)
        }
    }

    private func begin(
        timeout: TimeInterval,
        completion: @escaping (CLLocation?) -> Void
    ) {
        answer = completion
        manager.delegate = self
        // The map wants a room, not a doorstep, and the coarser accuracy is
        // both quicker to reach and cheaper on the battery.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters

        let deadline = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout, execute: deadline
        )

        manager.requestLocation()
    }

    private func finish(_ location: CLLocation?) {
        // Nil after the first answer, which is what makes the three racing
        // callers harmless.
        guard let answer else { return }
        self.answer = nil
        deadline?.cancel()
        deadline = nil
        manager.delegate = nil
        answer(location)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        finish(locations.last)
    }

    func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        // Nothing to report upward: failing to get a fix indoors is ordinary,
        // and the caller's fallback is the same either way.
        finish(nil)
    }
}
