package school.attractor.attractor_geo

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Great-circle distance, shared by everything here that measures how far the
 * device went.
 *
 * One copy rather than one per policy: `LocationFilter` and `MotionPolicy` ask
 * the same question, and two implementations of it would be two chances for
 * the platforms to drift apart in different places.
 */
object Distance {
    private const val EARTH_RADIUS_METERS = 6_371_000.0

    /** Haversine. Exact enough at the distances a person covers. */
    fun meters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val phi1 = Math.toRadians(lat1)
        val phi2 = Math.toRadians(lat2)
        val deltaPhi = Math.toRadians(lat2 - lat1)
        val deltaLambda = Math.toRadians(lon2 - lon1)

        val a = sin(deltaPhi / 2) * sin(deltaPhi / 2) +
            cos(phi1) * cos(phi2) *
            sin(deltaLambda / 2) * sin(deltaLambda / 2)

        return EARTH_RADIUS_METERS * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
