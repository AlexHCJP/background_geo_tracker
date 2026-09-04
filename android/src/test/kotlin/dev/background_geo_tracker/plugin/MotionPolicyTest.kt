package dev.background_geo_tracker.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MotionPolicyTest {

    private fun policy(
        stopTimeoutSeconds: Int = 300,
        stationaryRadiusMeters: Double = 150.0,
        elasticityMultiplier: Double = 1.0,
        baseDistanceFilterMeters: Double = 20.0,
    ) = MotionPolicy(
        stopTimeoutSeconds = stopTimeoutSeconds,
        stationaryRadiusMeters = stationaryRadiusMeters,
        elasticityMultiplier = elasticityMultiplier,
        baseDistanceFilterMeters = baseDistanceFilterMeters,
    )

    /** ~0.0009° of latitude is ~100 m; the anchor sits at (0, 0). */
    private val hundredMeters = 0.0009
    private val fiveHundredMeters = 0.0045

    @Test
    fun `silence shorter than the timeout keeps collecting`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)

        val decision = p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 299_000)

        assertTrue(decision is MotionPolicy.Decision.Continue)
        assertTrue(p.isMoving)
    }

    @Test
    fun `silence past the timeout switches the GPS off`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)

        val decision = p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 300_000)

        val stop = decision as MotionPolicy.Decision.Stop
        assertEquals(0.0, stop.anchorLat, 1e-9)
        assertEquals(150.0, stop.radiusMeters, 1e-9)
        assertEquals(300L, stop.stillSeconds)
        assertFalse(p.isMoving)
    }

    @Test
    fun `a fix beyond the radius restarts the count`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)

        // Well outside the 150 m radius, four minutes in: the anchor moves
        // here and the clock starts again, so the original deadline passes
        // with nothing happening.
        p.onFix(fiveHundredMeters, 0.0, speedMps = 1.4, atMillis = 240_000)
        val decision =
            p.onFix(fiveHundredMeters, 0.0, speedMps = 0.0, atMillis = 400_000)

        assertTrue(decision is MotionPolicy.Decision.Continue)
        assertTrue(p.isMoving)
    }

    @Test
    fun `drift inside the radius does not restart the count`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)

        // 100 m away is still inside 150 m: a phone on a desk whose fixes
        // wander must not hold the GPS on for ever.
        p.onFix(hundredMeters, 0.0, speedMps = 0.0, atMillis = 200_000)
        val decision = p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 301_000)

        assertTrue(decision is MotionPolicy.Decision.Stop)
    }

    @Test
    fun `a zero timeout switches stop detection off rather than to instant`() {
        // Read literally it would stop on the second fix of every session,
        // which is the opposite of what switching it off asks for.
        val p = policy(stopTimeoutSeconds = 0)
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)

        val decision = p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 86_400_000)

        assertTrue(decision is MotionPolicy.Decision.Continue)
        assertTrue(p.isMoving)
    }

    @Test
    fun `a detector wakes a stationary policy exactly once`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 300_000)

        assertTrue(p.onMovementDetected(310_000))
        assertTrue(p.isMoving)
        // The second detector answers a moment later. It must not be read as a
        // fresh transition, or the collector re-requests updates it already has.
        assertFalse(p.onMovementDetected(311_000))
    }

    @Test
    fun `a stray fix delivered after the stop does not resume the session`() {
        // CoreLocation and FusedLocation both keep delivering for a moment
        // after updates are removed. Waking is the detectors' job.
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 300_000)

        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 301_000)

        assertFalse(p.isMoving)
    }

    @Test
    fun `walking pace leaves the distance filter alone`() {
        val p = policy()

        assertEquals(20.0, p.distanceFilterFor(0.0), 1e-9)
        assertEquals(20.0, p.distanceFilterFor(1.39), 1e-9)
    }

    @Test
    fun `motorway speed stretches the filter but not past the ceiling`() {
        val p = policy()

        // 25 m/s is 90 km/h: 20 × (25 / 1.4) ≈ 357 m.
        assertEquals(357.14, p.distanceFilterFor(25.0), 0.01)
        // A bogus 300 m/s must not switch collection off in all but name.
        assertEquals(
            MotionPolicy.ELASTICITY_MAX_METERS,
            p.distanceFilterFor(300.0),
            1e-9,
        )
    }

    @Test
    fun `a zero multiplier switches stretching off rather than to zero`() {
        // Read literally the formula would give 0 m, which records every fix —
        // the opposite of what switching elasticity off asks for.
        val p = policy(elasticityMultiplier = 0.0)

        assertEquals(20.0, p.distanceFilterFor(25.0), 1e-9)
        assertEquals(20.0, p.steppedDistanceFilterFor(25.0), 1e-9)
    }

    @Test
    fun `steps are multiples of the base filter`() {
        val p = policy()

        // 357 m rounds down to 20 × 10; going up would space points out
        // further than elasticity asked for.
        assertEquals(200.0, p.steppedDistanceFilterFor(25.0), 1e-9)
        assertEquals(20.0, p.steppedDistanceFilterFor(1.0), 1e-9)
        assertEquals(40.0, p.steppedDistanceFilterFor(3.0), 1e-9)
    }

    @Test
    fun `neighbouring speeds inside one step do not rebuild the request`() {
        // Android has to tear down and re-request location updates to change
        // the filter, so doing it per fix would cost more than elasticity saves.
        val p = policy()

        val first = p.onFix(0.0, 0.0, speedMps = 25.0, atMillis = 0)
            as MotionPolicy.Decision.Continue
        val second =
            p.onFix(hundredMeters, 0.0, speedMps = 26.0, atMillis = 10_000)
                as MotionPolicy.Decision.Continue
        val third =
            p.onFix(fiveHundredMeters, 0.0, speedMps = 1.0, atMillis = 20_000)
                as MotionPolicy.Decision.Continue

        assertTrue(first.stepChanged)
        assertEquals(200.0, first.steppedDistanceFilterMeters, 1e-9)
        assertFalse(second.stepChanged)
        assertTrue(third.stepChanged)
        assertEquals(20.0, third.steppedDistanceFilterMeters, 1e-9)
    }

    @Test
    fun `reset forgets the previous session`() {
        val p = policy()
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 0)
        p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 300_000)

        p.reset()

        assertTrue(p.isMoving)
        // The old anchor is gone: the first fix of the new session becomes it,
        // so a session opened a hundred kilometres away is not instantly "moving".
        val decision = p.onFix(0.0, 0.0, speedMps = 0.0, atMillis = 400_000)
        assertTrue(decision is MotionPolicy.Decision.Continue)
    }
}
