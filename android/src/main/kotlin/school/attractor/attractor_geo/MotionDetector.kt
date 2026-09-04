package school.attractor.attractor_geo

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

/**
 * The two things that wake a collector whose GPS is off.
 *
 * Both are armed, always, because they answer at different distances: Activity
 * Recognition notices a few metres after somebody starts walking, and the
 * geofence answers at roughly 200 m whatever radius is asked for. Whichever
 * fires first is the one that wakes the session, and the slow one is what
 * keeps the session recoverable when the fast one is refused or absent.
 *
 * Both deliver into [GeoTrackingService] through a `PendingIntent`. The
 * service is deliberately still alive while stationary — only the GPS is off —
 * so this is a delivery to a running foreground service rather than a
 * background start, which Android 12 and later would refuse.
 */
class MotionDetector(private val context: Context) {

    private val geofences = LocationServices.getGeofencingClient(context)
    private val activities = ActivityRecognition.getClient(context)

    private val pending: PendingIntent by lazy {
        val intent = Intent(context, GeoTrackingService::class.java)
            .setAction(ACTION_MOTION_WAKE)
        PendingIntent.getService(
            context,
            REQUEST_CODE,
            intent,
            // Mutable because both GMS APIs fill the intent's extras in on
            // delivery; an immutable one arrives empty and the wake has no
            // source to report.
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                },
        )
    }

    /**
     * Arms both detectors around the anchor. Returns what actually got armed,
     * for the log: a session that wakes late is otherwise indistinguishable
     * from one that never armed anything at all.
     */
    fun arm(lat: Double, lon: Double, radiusMeters: Double): String {
        val armed = mutableListOf<String>()

        val geofence = Geofence.Builder()
            .setRequestId(ANCHOR_ID)
            .setCircularRegion(lat, lon, radiusMeters.toFloat())
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            // No initial trigger: the device is inside the region by
            // construction, and asking for one would fire an ENTER the moment
            // the fence is set — waking the collector it was just put to sleep.
            .setInitialTrigger(0)
            .addGeofence(geofence)
            .build()

        try {
            geofences.addGeofences(request, pending)
            armed += "geofence"
        } catch (e: SecurityException) {
            // Background location revoked between the stop and here. The
            // session stays stationary until the app is opened, which is worse
            // than waking late and better than crashing the collector.
            return "nothing: ${e.message ?: "geofence refused"}"
        }

        if (GeoStatus.motionPermissionName(context) == "granted") {
            val transitions = listOf(
                DetectedActivity.WALKING,
                DetectedActivity.ON_BICYCLE,
                DetectedActivity.IN_VEHICLE,
            ).map { type ->
                ActivityTransition.Builder()
                    .setActivityType(type)
                    .setActivityTransition(
                        ActivityTransition.ACTIVITY_TRANSITION_ENTER,
                    )
                    .build()
            }
            try {
                activities.requestActivityTransitionUpdates(
                    ActivityTransitionRequest(transitions),
                    pending,
                )
                armed += "activity"
            } catch (_: SecurityException) {
                // Recorded by omission: the caller logs what came back.
            }
        }

        return armed.joinToString("+")
    }

    /** Takes both down. Safe to call when nothing was armed. */
    fun disarm() {
        try {
            geofences.removeGeofences(pending)
            activities.removeActivityTransitionUpdates(pending)
        } catch (_: SecurityException) {
            // Nothing to do: a detector we are not allowed to remove is one we
            // were not allowed to add.
        }
    }

    /**
     * Which detector delivered this intent, for the log line. Activity first,
     * because a geofence intent carries no activity extra and the reverse is
     * also true — the order only matters if a future Android delivers both.
     */
    fun sourceOf(intent: Intent): String = when {
        ActivityTransitionResult.hasResult(intent) -> "activity"
        GeofencingEvent.fromIntent(intent)?.hasError() == false -> "geofence"
        else -> "unknown"
    }

    companion object {
        const val ACTION_MOTION_WAKE = "school.attractor.attractor_geo.MOTION_WAKE"
        private const val ANCHOR_ID = "attractor_geo_anchor"
        private const val REQUEST_CODE = 4712
    }
}
