package dev.background_geo_tracker.plugin

import kotlin.math.min

/**
 * Decides when the collector may switch the GPS off, when it has to come back,
 * and how far apart points are spaced while it is on.
 *
 * Must stay behaviourally identical to the Swift `MotionPolicy`, for the same
 * reason `LocationFilter` and `UploadPolicy` must: a phone that decides it is
 * standing still on one platform and moving on the other is a difference
 * nobody can see until two of them lie side by side and only one keeps
 * drawing.
 *
 * Pure and stateful — no Android types, no clock of its own, every input
 * passed in. That is what makes the whole of it unit-testable, which matters
 * here more than usual: the thing it switches off is the thing the package
 * exists to do.
 *
 * Single-threaded by way of its owner: the collector calls it from the
 * location callback and from the wake path, both on the main looper.
 */
class MotionPolicy(
    private val stopTimeoutSeconds: Int,
    private val stationaryRadiusMeters: Double,
    private val elasticityMultiplier: Double,
    private val baseDistanceFilterMeters: Double,
) {
    /** What the collector should do with the fix it just handed over. */
    sealed interface Decision {
        /**
         * Keep collecting. [distanceFilterMeters] is what iOS assigns as it
         * stands; [steppedDistanceFilterMeters] is the same value snapped to a
         * step, which is what Android requests, and [stepChanged] says whether
         * that step is new — on Android, whether the request has to be rebuilt
         * at all.
         */
        data class Continue(
            val distanceFilterMeters: Double,
            val steppedDistanceFilterMeters: Double,
            val stepChanged: Boolean,
        ) : Decision

        /**
         * Stop asking for fixes and arm the detectors around the anchor.
         * [stillSeconds] is for the log line, which is the only place the
         * decision can be reviewed after the fact.
         */
        data class Stop(
            val anchorLat: Double,
            val anchorLon: Double,
            val radiusMeters: Double,
            val stillSeconds: Long,
        ) : Decision
    }

    /** Whether the collector should currently be asking for fixes. */
    var isMoving: Boolean = true
        private set

    /** The last fix that moved further than the radius, and when it arrived. */
    private var anchorLat = 0.0
    private var anchorLon = 0.0
    private var anchorMillis = 0L
    private var hasAnchor = false

    /** The step the collector last requested, so a repeat is not a change. */
    private var appliedStep = baseDistanceFilterMeters

    /**
     * Forgets the session. A new one must not inherit an anchor from wherever
     * the last one ended — the device may be a country away, and one stale
     * anchor would read as movement for ever.
     */
    fun reset() {
        isMoving = true
        hasAnchor = false
        anchorLat = 0.0
        anchorLon = 0.0
        anchorMillis = 0L
        appliedStep = baseDistanceFilterMeters
    }

    /**
     * Judges a fix that has already survived `LocationFilter`.
     *
     * Rejected fixes deliberately do not reach here: a fix thrown out for a
     * 1 km accuracy radius is not evidence of where the device is, and letting
     * it move the anchor would keep the GPS on all night in a basement.
     *
     * [speedMps] is the fix's own speed where the OS reports one, and a
     * negative or absent value must be passed as `0.0` — treated as "no
     * information", which leaves the filter at its base.
     */
    fun onFix(
        lat: Double,
        lon: Double,
        speedMps: Double,
        atMillis: Long,
    ): Decision {
        if (!hasAnchor) {
            anchor(lat, lon, atMillis)
            return continueWith(speedMps)
        }

        val moved = Distance.meters(anchorLat, anchorLon, lat, lon)
        if (moved > stationaryRadiusMeters) {
            anchor(lat, lon, atMillis)
            return continueWith(speedMps)
        }

        // A fix arriving while stationary is a late delivery, not a wake-up:
        // both location APIs keep handing over for a moment after updates are
        // removed. Waking is the detectors' job, and letting a straggler do it
        // would undo the stop the moment it was made.
        if (!isMoving) return continueWith(speedMps)

        // Zero disables the machine, the way a zero multiplier disables
        // elasticity. Read literally it would mean "stop the moment a fix
        // repeats", which is the opposite of what switching stop detection
        // off asks for — and it would switch the GPS off on the second fix of
        // every session.
        if (stopTimeoutSeconds <= 0) return continueWith(speedMps)

        val stillMillis = atMillis - anchorMillis
        if (stillMillis >= stopTimeoutSeconds * 1000L) {
            isMoving = false
            return Decision.Stop(
                anchorLat = anchorLat,
                anchorLon = anchorLon,
                radiusMeters = stationaryRadiusMeters,
                stillSeconds = stillMillis / 1000,
            )
        }

        return continueWith(speedMps)
    }

    /**
     * A detector fired. True when this is the transition — the collector acts
     * on it — and false when the policy was already moving, which is the
     * ordinary case of the second detector answering a moment after the first.
     */
    fun onMovementDetected(atMillis: Long): Boolean {
        if (isMoving) return false
        isMoving = true
        // The anchor is dropped rather than kept: where the device is now is
        // unknown, and the next fix is the honest answer. Keeping the old one
        // would start the stillness clock from a position the device may have
        // already left.
        hasAnchor = false
        anchorMillis = atMillis
        appliedStep = baseDistanceFilterMeters
        return true
    }

    /**
     * The filter this speed asks for, unrounded. iOS assigns this directly —
     * changing `CLLocationManager.distanceFilter` costs one assignment.
     */
    fun distanceFilterFor(speedMps: Double): Double {
        // Zero means "off". In the formula it would mean a filter of zero
        // metres, which records every fix — the opposite of the request.
        if (elasticityMultiplier == 0.0) return baseDistanceFilterMeters

        val scale = (speedMps / WALKING_MPS) * elasticityMultiplier
        // Below walking pace the filter never tightens: a slow reading is far
        // more often a bad fix than an actual crawl.
        if (scale <= 1.0) return baseDistanceFilterMeters

        return min(baseDistanceFilterMeters * scale, ELASTICITY_MAX_METERS)
    }

    /**
     * The same value snapped down to the nearest step. Android needs this:
     * changing `setMinUpdateDistanceMeters` means tearing the request down and
     * building it again, and doing that per fix costs more than elasticity
     * saves.
     *
     * Steps are multiples of the base filter rather than absolute metres, so
     * they keep meaning something after somebody changes the base.
     */
    fun steppedDistanceFilterFor(speedMps: Double): Double {
        val wanted = distanceFilterFor(speedMps)
        // Down, never up: a step above `wanted` would space points out further
        // than elasticity asked for.
        return STEP_MULTIPLES
            .map { baseDistanceFilterMeters * it }
            .lastOrNull { it <= wanted }
            ?: baseDistanceFilterMeters
    }

    private fun anchor(lat: Double, lon: Double, atMillis: Long) {
        anchorLat = lat
        anchorLon = lon
        anchorMillis = atMillis
        hasAnchor = true
    }

    private fun continueWith(speedMps: Double): Decision.Continue {
        val stepped = steppedDistanceFilterFor(speedMps)
        val changed = stepped != appliedStep
        appliedStep = stepped
        return Decision.Continue(
            distanceFilterMeters = distanceFilterFor(speedMps),
            steppedDistanceFilterMeters = stepped,
            stepChanged = changed,
        )
    }

    companion object {
        /** A normal walking pace. Below it elasticity does nothing. */
        const val WALKING_MPS = 1.4

        /**
         * The widest the filter may be stretched to.
         *
         * At 500 m a road is still recognisably drawn, and the ceiling is what
         * keeps one absurd speed reading — a GPS glitch claiming 300 m/s —
         * from switching collection off in all but name.
         */
        const val ELASTICITY_MAX_METERS = 500.0

        /** Multiples of the base filter the stepped value snaps to. */
        val STEP_MULTIPLES = listOf(1.0, 2.0, 5.0, 10.0, 20.0)
    }
}
