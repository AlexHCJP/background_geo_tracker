package school.attractor.attractor_geo

import android.content.Context
import android.location.Location
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource

/**
 * One fix, asked for and answered once.
 *
 * Nothing to do with the tracking service: a read must not need a foreground
 * service, a notification or a session, and must not start one. It is a
 * question about where the device is, asked of the same provider the session
 * would use.
 *
 * Answers on the main thread, which is where Play Services delivers its tasks
 * and where the method channel has to be replied on.
 */
object OneShotLocation {

    /**
     * A cached fix younger than this is handed straight back. Waiting for a
     * fresh one costs the seconds the caller is asking to avoid, and a fix a
     * minute old is the same room.
     */
    private const val CACHE_MAX_AGE_MILLIS = 60_000L

    /**
     * Deliberately not [Priority.PRIORITY_HIGH_ACCURACY], which the session
     * uses: a caller who needs an answer now wants the network fix that
     * arrives indoors in a second, not the GPS lock that does not.
     */
    private const val PRIORITY = Priority.PRIORITY_BALANCED_POWER_ACCURACY

    /**
     * Calls [onResult] exactly once, with null when the permission is missing
     * or nothing arrives within [timeoutSeconds].
     */
    fun request(
        context: Context,
        timeoutSeconds: Int,
        onResult: (Location?) -> Unit,
    ) {
        // Asking without the permission throws, and prompting is not this
        // method's business: a screen asking where it is must not be what puts
        // a permission dialog in front of the user.
        if (!GeoStatus.hasForegroundLocation(context)) {
            onResult(null)
            return
        }

        val client = LocationServices.getFusedLocationProviderClient(context)
        // The request carries both halves of the contract: `maxUpdateAge`
        // returns a recent cached fix without waking a radio, and `duration`
        // is the timeout, applied by Play Services rather than by a handler
        // racing it from here.
        val request = CurrentLocationRequest.Builder()
            .setPriority(PRIORITY)
            .setMaxUpdateAgeMillis(CACHE_MAX_AGE_MILLIS)
            .setDurationMillis(timeoutSeconds * 1000L)
            .build()

        try {
            client.getCurrentLocation(
                request,
                CancellationTokenSource().token,
            )
                .addOnSuccessListener { location ->
                    if (location != null) {
                        onResult(location)
                    } else {
                        lastKnown(context, onResult)
                    }
                }
                .addOnFailureListener { lastKnown(context, onResult) }
        } catch (_: SecurityException) {
            // Revoked between the check above and the call, which some OEM
            // builds report this way rather than through the task.
            onResult(null)
        }
    }

    /**
     * The fallback: whatever the provider last saw, however old.
     *
     * Somewhere the reader was is worth more to a map than nothing at all, and
     * the point carries its own timestamp for a caller that disagrees.
     */
    private fun lastKnown(context: Context, onResult: (Location?) -> Unit) {
        try {
            LocationServices.getFusedLocationProviderClient(context)
                .lastLocation
                .addOnSuccessListener { onResult(it) }
                .addOnFailureListener { onResult(null) }
        } catch (_: SecurityException) {
            onResult(null)
        }
    }
}
