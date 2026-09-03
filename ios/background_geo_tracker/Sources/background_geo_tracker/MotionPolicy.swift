import Foundation

/// Decides when the collector may switch the GPS off, when it has to come
/// back, and how far apart points are spaced while it is on.
///
/// Must stay behaviourally identical to the Kotlin `MotionPolicy`, for the
/// same reason `LocationFilter` and `UploadPolicy` must: a phone that decides
/// it is standing still on one platform and moving on the other is a
/// difference nobody can see until two of them lie side by side and only one
/// keeps drawing.
///
/// Pure and stateful — no CoreLocation types, no clock of its own, every input
/// passed in. Single-threaded by way of its owner, which calls it from the
/// location delegate and from the wake path, both on the main queue.
final class MotionPolicy {
    /// What the collector should do with the fix it just handed over.
    ///
    /// `keepGoing` is Kotlin's `Decision.Continue` — `continue` is a keyword
    /// here. Everything else is named the same on purpose.
    enum Decision {
        /// Keep collecting. `distanceFilterMeters` is what this platform
        /// assigns; the stepped value and `stepChanged` exist for Android,
        /// which has to rebuild its request to change the filter, and are used
        /// here only to decide whether the change is worth a log line.
        case keepGoing(
            distanceFilterMeters: Double,
            steppedDistanceFilterMeters: Double,
            stepChanged: Bool
        )

        /// Stop asking for fixes and arm the detectors around the anchor.
        /// `stillSeconds` is for the log line, which is the only place the
        /// decision can be reviewed after the fact.
        case stop(
            anchorLat: Double,
            anchorLon: Double,
            radiusMeters: Double,
            stillSeconds: Int64
        )
    }

    /// A normal walking pace. Below it elasticity does nothing.
    static let walkingMps = 1.4

    /// The widest the filter may be stretched to.
    ///
    /// At 500 m a road is still recognisably drawn, and the ceiling is what
    /// keeps one absurd speed reading — a GPS glitch claiming 300 m/s — from
    /// switching collection off in all but name.
    static let elasticityMaxMeters = 500.0

    /// Multiples of the base filter the stepped value snaps to.
    static let stepMultiples: [Double] = [1, 2, 5, 10, 20]

    private let stopTimeoutSeconds: Int
    private let stationaryRadiusMeters: Double
    private let elasticityMultiplier: Double
    private let baseDistanceFilterMeters: Double

    /// Whether the collector should currently be asking for fixes.
    private(set) var isMoving = true

    /// The last fix that moved further than the radius, and when it arrived.
    private var anchorLat = 0.0
    private var anchorLon = 0.0
    private var anchorMillis: Int64 = 0
    private var hasAnchor = false

    /// The step the collector last applied, so a repeat is not a change.
    private var appliedStep: Double

    init(
        stopTimeoutSeconds: Int,
        stationaryRadiusMeters: Double,
        elasticityMultiplier: Double,
        baseDistanceFilterMeters: Double
    ) {
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.stationaryRadiusMeters = stationaryRadiusMeters
        self.elasticityMultiplier = elasticityMultiplier
        self.baseDistanceFilterMeters = baseDistanceFilterMeters
        self.appliedStep = baseDistanceFilterMeters
    }

    /// Forgets the session. A new one must not inherit an anchor from wherever
    /// the last one ended — the device may be a country away, and one stale
    /// anchor would read as movement for ever.
    func reset() {
        isMoving = true
        hasAnchor = false
        anchorLat = 0
        anchorLon = 0
        anchorMillis = 0
        appliedStep = baseDistanceFilterMeters
    }

    /// Judges a fix that has already survived `LocationFilter`.
    ///
    /// Rejected fixes deliberately do not reach here: a fix thrown out for a
    /// 1 km accuracy radius is not evidence of where the device is, and
    /// letting it move the anchor would keep the GPS on all night in a
    /// basement.
    ///
    /// `speedMps` must be `0` where the OS reports none — CoreLocation uses a
    /// negative speed for that, and passing it through would read as motion in
    /// reverse.
    func onFix(
        lat: Double, lon: Double, speedMps: Double, atMillis: Int64
    ) -> Decision {
        if !hasAnchor {
            anchor(lat: lat, lon: lon, atMillis: atMillis)
            return keepGoing(speedMps: speedMps)
        }

        let moved = Distance.meters(anchorLat, anchorLon, lat, lon)
        if moved > stationaryRadiusMeters {
            anchor(lat: lat, lon: lon, atMillis: atMillis)
            return keepGoing(speedMps: speedMps)
        }

        // A fix arriving while stationary is a late delivery, not a wake-up:
        // both location APIs keep handing over for a moment after updates are
        // removed. Waking is the detectors' job, and letting a straggler do it
        // would undo the stop the moment it was made.
        guard isMoving else { return keepGoing(speedMps: speedMps) }

        // Zero disables the machine, the way a zero multiplier disables
        // elasticity. Read literally it would switch the GPS off on the second
        // fix of every session.
        guard stopTimeoutSeconds > 0 else { return keepGoing(speedMps: speedMps) }

        let stillMillis = atMillis - anchorMillis
        if stillMillis >= Int64(stopTimeoutSeconds) * 1000 {
            isMoving = false
            return .stop(
                anchorLat: anchorLat,
                anchorLon: anchorLon,
                radiusMeters: stationaryRadiusMeters,
                stillSeconds: stillMillis / 1000
            )
        }

        return keepGoing(speedMps: speedMps)
    }

    /// A detector fired. True when this is the transition — the collector acts
    /// on it — and false when the policy was already moving, which is the
    /// ordinary case of the second detector answering a moment after the first.
    func onMovementDetected(atMillis: Int64) -> Bool {
        guard !isMoving else { return false }
        isMoving = true
        // The anchor is dropped rather than kept: where the device is now is
        // unknown, and the next fix is the honest answer.
        hasAnchor = false
        anchorMillis = atMillis
        appliedStep = baseDistanceFilterMeters
        return true
    }

    /// The filter this speed asks for, unrounded. Assigned directly here —
    /// changing `CLLocationManager.distanceFilter` costs one assignment.
    func distanceFilterFor(speedMps: Double) -> Double {
        // Zero means "off". In the formula it would mean a filter of zero
        // metres, which records every fix — the opposite of the request.
        if elasticityMultiplier == 0 { return baseDistanceFilterMeters }

        let scale = (speedMps / Self.walkingMps) * elasticityMultiplier
        // Below walking pace the filter never tightens: a slow reading is far
        // more often a bad fix than an actual crawl.
        if scale <= 1 { return baseDistanceFilterMeters }

        return min(baseDistanceFilterMeters * scale, Self.elasticityMaxMeters)
    }

    /// The same value snapped down to the nearest step, which is what Android
    /// requests. Kept here so both platforms answer from one implementation.
    func steppedDistanceFilterFor(speedMps: Double) -> Double {
        let wanted = distanceFilterFor(speedMps: speedMps)
        // Down, never up: a step above `wanted` would space points out further
        // than elasticity asked for.
        return Self.stepMultiples
            .map { baseDistanceFilterMeters * $0 }
            .last { $0 <= wanted } ?? baseDistanceFilterMeters
    }

    private func anchor(lat: Double, lon: Double, atMillis: Int64) {
        anchorLat = lat
        anchorLon = lon
        anchorMillis = atMillis
        hasAnchor = true
    }

    private func keepGoing(speedMps: Double) -> Decision {
        let stepped = steppedDistanceFilterFor(speedMps: speedMps)
        let changed = stepped != appliedStep
        appliedStep = stepped
        return .keepGoing(
            distanceFilterMeters: distanceFilterFor(speedMps: speedMps),
            steppedDistanceFilterMeters: stepped,
            stepChanged: changed
        )
    }
}
