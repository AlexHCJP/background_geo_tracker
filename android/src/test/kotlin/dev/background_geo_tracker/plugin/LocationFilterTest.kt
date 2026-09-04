package dev.background_geo_tracker.plugin

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Swift `LocationFilterTests` mirror these case for case. A change here
 * that is not made there is the two platforms drifting apart about which fixes
 * are real, which is exactly what a shared policy exists to prevent.
 */
class LocationFilterTest {

    private fun filter(
        accuracy: Double = 100.0,
        displacement: Double = 1.0,
        speed: Double = 60.0,
        noise: Double = 3.0,
    ) = LocationFilter(accuracy, displacement, speed, noise)

    /** Moscow, and a second point 100 m north of it. */
    private val lat = 55.751244
    private val lon = 37.618423
    private val latPlus100m = 55.752143

    private fun accepted(verdict: LocationFilter.Verdict) =
        verdict as LocationFilter.Verdict.Accept

    @Test
    fun `the first fix of a session is taken at face value`() {
        val verdict = filter().apply(lat, lon, 12.0, 1_000L)

        val accept = accepted(verdict)
        assertEquals(lat, accept.lat, 1e-9)
        assertEquals(lon, accept.lon, 1e-9)
        // Not smoothed against anything, so the claim stands as made.
        assertEquals(12.0, accept.accuracy, 1e-9)
    }

    @Test
    fun `a fix worse than the accuracy threshold is rejected`() {
        val subject = filter(accuracy = 100.0)

        val verdict = subject.apply(lat, lon, 1500.0, 1_000L)

        assertTrue(verdict is LocationFilter.Verdict.Reject)
    }

    @Test
    fun `a threshold rejection does not become the reference point`() {
        val subject = filter(accuracy = 100.0)

        // A cell-tower fix arrives first and is thrown away. The GPS fix that
        // follows must be treated as the session's first, not measured against
        // the one that was discarded.
        subject.apply(lat, lon, 1500.0, 1_000L)
        val verdict = subject.apply(latPlus100m, lon, 10.0, 2_000L)

        val accept = accepted(verdict)
        assertEquals(latPlus100m, accept.lat, 1e-9)
    }

    @Test
    fun `a fix that has not moved far enough is rejected`() {
        val subject = filter(displacement = 10.0)
        subject.apply(lat, lon, 10.0, 1_000L)

        // Roughly 1 cm away.
        val verdict = subject.apply(lat + 0.0000001, lon, 10.0, 11_000L)

        assertTrue(verdict is LocationFilter.Verdict.Reject)
    }

    @Test
    fun `a fix implying an impossible speed is rejected`() {
        val subject = filter(speed = 60.0)
        subject.apply(lat, lon, 10.0, 0L)

        // 100 m in a tenth of a second is 1000 m/s.
        val verdict = subject.apply(latPlus100m, lon, 10.0, 100L)

        assertTrue(verdict is LocationFilter.Verdict.Reject)
    }

    @Test
    fun `the same displacement over a plausible interval is accepted`() {
        val subject = filter(speed = 60.0)
        subject.apply(lat, lon, 10.0, 0L)

        // The same 100 m, now over 10 seconds — a fast run, not a teleport.
        val verdict = subject.apply(latPlus100m, lon, 10.0, 10_000L)

        assertTrue(verdict is LocationFilter.Verdict.Accept)
    }

    @Test
    fun `a speed rejection is measured against the raw position`() {
        val subject = filter(speed = 60.0)
        subject.apply(lat, lon, 10.0, 0L)
        subject.apply(latPlus100m, lon, 10.0, 10_000L)

        // Smoothing pulls the stored estimate back toward the first fix. If
        // the next fix were judged against that estimate rather than against
        // the raw position, continuing at the same real speed would start
        // reading as an impossible one.
        val verdict = subject.apply(55.753042, lon, 10.0, 20_000L)

        assertTrue(verdict is LocationFilter.Verdict.Accept)
    }

    @Test
    fun `smoothing pulls an uncertain fix toward the established position`() {
        val subject = filter(noise = 0.1)
        subject.apply(lat, lon, 5.0, 0L)

        // A 90 m fix 100 m away, ten seconds later — an interval the speed
        // check is comfortable with, so what is being tested here is only the
        // smoothing. Barely believed, so the reported position lands nearer
        // where we were than where it claims.
        val accept = accepted(subject.apply(latPlus100m, lon, 90.0, 10_000L))

        assertTrue(
            "expected the estimate below the midpoint, got ${accept.lat}",
            accept.lat < (lat + latPlus100m) / 2,
        )
        assertTrue(accept.lat > lat)
    }

    @Test
    fun `a confident fix moves the estimate most of the way`() {
        val subject = filter(noise = 3.0)
        subject.apply(lat, lon, 50.0, 0L)

        // The mirror of the case above: a 3 m fix against a 50 m history is
        // believed, so the estimate goes nearly all the way to it.
        val accept = accepted(subject.apply(latPlus100m, lon, 3.0, 10_000L))

        assertTrue(
            "expected the estimate past the midpoint, got ${accept.lat}",
            accept.lat > (lat + latPlus100m) / 2,
        )
    }

    @Test
    fun `reported accuracy tightens as agreeing fixes arrive`() {
        val subject = filter(noise = 0.1)
        val first = accepted(subject.apply(lat, lon, 20.0, 0L))
        val second = accepted(subject.apply(lat + 0.0001, lon, 20.0, 1_000L))
        val third = accepted(subject.apply(lat + 0.0002, lon, 20.0, 2_000L))

        assertTrue(second.accuracy < first.accuracy)
        assertTrue(third.accuracy < second.accuracy)
    }

    @Test
    fun `a zero accuracy claim cannot freeze the estimate`() {
        val subject = filter()
        subject.apply(lat, lon, 0.0, 0L)

        // Believing a zero-error claim absolutely would set the variance to 0
        // and make every later gain 0 — the estimate would never move again.
        val accept = accepted(subject.apply(latPlus100m, lon, 10.0, 5_000L))

        assertTrue(abs(accept.lat - lat) > 1e-7)
    }

    @Test
    fun `reset forgets the session`() {
        val subject = filter(displacement = 10.0)
        subject.apply(lat, lon, 10.0, 1_000L)

        subject.reset()

        // Without the reset this sits inside the displacement floor and is
        // rejected; after it, it is simply the first fix of a new session.
        val accept = accepted(subject.apply(lat, lon, 10.0, 2_000L))
        assertEquals(lat, accept.lat, 1e-9)
        assertEquals(10.0, accept.accuracy, 1e-9)
    }
}
