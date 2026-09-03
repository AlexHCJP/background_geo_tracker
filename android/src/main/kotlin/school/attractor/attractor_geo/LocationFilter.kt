package school.attractor.attractor_geo

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Decides which fixes are real and where the real ones actually are.
 *
 * Must stay behaviourally identical to the Swift `LocationFilter`, for the
 * same reason `UploadPolicy` must: a point accepted on one platform and
 * rejected on the other is a difference nobody can see until two phones
 * standing side by side disagree about where they are.
 *
 * Stateful and session-scoped — it remembers the last accepted fix and the
 * smoother's running estimate. One instance per collector, [reset] when a
 * session opens.
 */
class LocationFilter(
    private val accuracyThresholdMeters: Double,
    private val minDisplacementMeters: Double,
    private val maxImpliedSpeedMps: Double,
    private val kalmanProcessNoiseMps: Double,
) {
    /** Why a fix was turned away, or that it was kept. */
    sealed interface Verdict {
        /** Keep it — at these coordinates, which may not be the ones offered. */
        data class Accept(
            val lat: Double,
            val lon: Double,
            val accuracy: Double,
        ) : Verdict

        /** Drop it. [reason] is for logs, never for control flow. */
        data class Reject(val reason: String) : Verdict
    }

    /** Where the last accepted fix was *observed*, not where it was smoothed to. */
    private var lastLat: Double? = null
    private var lastLon: Double? = null
    private var lastMillis: Long = 0

    /** The smoother's running estimate, and how far off it might be. */
    private var estimateLat = 0.0
    private var estimateLon = 0.0

    /**
     * Positional variance in square metres. Negative means the smoother has
     * never run, which is how the first fix of a session is taken at face
     * value instead of being averaged against nothing.
     */
    private var variance = -1.0

    /** Forgets the session. A new one must not be pulled toward the old one. */
    fun reset() {
        lastLat = null
        lastLon = null
        lastMillis = 0
        estimateLat = 0.0
        estimateLon = 0.0
        variance = -1.0
    }

    /**
     * Runs the three rejections, then smooths whatever survives.
     *
     * The order is not arbitrary. The cheap self-refuting checks come first so
     * a garbage fix never reaches the smoother, because the smoother has no
     * way to reject anything — handed a fix from 5 km away it does not discard
     * it, it drags the estimate a good part of the way there.
     */
    fun apply(
        lat: Double,
        lon: Double,
        accuracy: Double,
        recordedAtMillis: Long,
    ): Verdict {
        if (accuracy > accuracyThresholdMeters) {
            return Verdict.Reject("accuracy ${accuracy.toInt()}m")
        }

        val previousLat = lastLat
        val previousLon = lastLon

        // Elapsed time comes from the fixes themselves rather than the clock,
        // so a fix judged late is judged on when it actually happened.
        val elapsedSeconds = abs(recordedAtMillis - lastMillis) / 1000.0

        if (previousLat != null && previousLon != null) {
            val moved = Distance.meters(previousLat, previousLon, lat, lon)

            if (moved < minDisplacementMeters) {
                return Verdict.Reject("stationary ${moved.toInt()}m")
            }

            if (elapsedSeconds > 0) {
                val impliedSpeed = moved / elapsedSeconds
                if (impliedSpeed > maxImpliedSpeedMps) {
                    return Verdict.Reject("implied ${impliedSpeed.toInt()}m/s")
                }
            }
        }

        val accepted = smooth(lat, lon, accuracy, elapsedSeconds)

        // Deliberately the *raw* position, not the smoothed one. The next
        // fix's displacement and speed have to be measured against where the
        // device was observed to be, or the smoother's own lag starts feeding
        // the rejections and a genuine sprint begins to read as a teleport.
        lastLat = lat
        lastLon = lon
        lastMillis = recordedAtMillis

        return accepted
    }

    /**
     * A constant-position Kalman filter over latitude and longitude.
     *
     * One dimension, no matrices: with no velocity term the state is just the
     * position and its variance, and the whole update is four lines. What it
     * buys is that each fix moves the estimate in proportion to how much that
     * fix claims to be worth — a 10 m fix pulls hard, a 90 m fix barely at
     * all — instead of the queue taking every claim at face value.
     */
    private fun smooth(
        lat: Double,
        lon: Double,
        accuracy: Double,
        elapsedSeconds: Double,
    ): Verdict.Accept {
        // An accuracy of zero would make the gain 1 and the variance 0: that
        // fix would be believed absolutely and every fix after it ignored.
        val claimed = maxOf(accuracy, 1.0)
        val measurementVariance = claimed * claimed

        if (variance < 0) {
            estimateLat = lat
            estimateLon = lon
            variance = measurementVariance
            return Verdict.Accept(lat, lon, accuracy)
        }

        // Uncertainty grows with time, because the device may have moved while
        // nothing was being observed.
        if (elapsedSeconds > 0) {
            variance += elapsedSeconds *
                kalmanProcessNoiseMps * kalmanProcessNoiseMps
        }

        val gain = variance / (variance + measurementVariance)
        estimateLat += gain * (lat - estimateLat)
        estimateLon += gain * (lon - estimateLon)
        variance *= (1 - gain)

        // Reported accuracy follows the estimate rather than the raw fix, so
        // the number keeps meaning what it meant: how far off this coordinate
        // might be. Smoothing genuinely reduces that, and reporting the raw
        // claim instead would overstate the error of a position the backend
        // stores and shows to other people.
        return Verdict.Accept(estimateLat, estimateLon, sqrt(variance))
    }
}
