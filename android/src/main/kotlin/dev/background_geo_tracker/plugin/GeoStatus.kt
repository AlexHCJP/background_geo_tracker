package dev.background_geo_tracker.plugin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import androidx.core.content.ContextCompat

/**
 * The single source of truth for the status payload. Both the plugin and the
 * upload worker report status, and they must not disagree — an uploader that
 * invents "permission: always" tells the UI a comfortable lie at exactly the
 * moment something has gone wrong.
 */
object GeoStatus {

    fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun hasForegroundLocation(context: Context): Boolean =
        granted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    fun hasBackgroundLocation(context: Context): Boolean =
        hasForegroundLocation(context) &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION))

    /**
     * [activity] is only needed to tell a re-askable denial from a permanent
     * one. Without it — from a worker, say — a denial is reported as the
     * re-askable `denied`, and the plugin corrects it when an activity exists.
     *
     * [everRequested] is essential: `shouldShowRequestPermissionRationale`
     * returns false both *before the first ask* and *after a permanent
     * denial*. Without the flag a fresh install reports
     * `permanently_denied`, and the UI sends the user to system settings
     * instead of showing the prompt they have never seen.
     */
    fun permissionName(
        context: Context,
        activity: Activity?,
        everRequested: Boolean,
    ): String {
        val fine = granted(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val background = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

        return when {
            fine && background -> "always"
            fine -> "when_in_use"
            activity != null && everRequested &&
                !ActivityCompat.shouldShowRequestPermissionRationale(
                    activity,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ) -> "permanently_denied"
            else -> "denied"
        }
    }

    /**
     * Whether the OS is handing over real coordinates or a rough area.
     *
     * `FINE` is the whole test. Android 12 split the runtime prompt into
     * Precise and Approximate, and the Approximate half grants `COARSE`
     * alone — which [hasForegroundLocation] accepts, so the session runs and
     * every fix in it is off by a kilometre or more with nothing else in the
     * status saying so.
     */
    fun preciseLocation(context: Context): Boolean =
        granted(context, Manifest.permission.ACCESS_FINE_LOCATION)

    /**
     * Whether the app owes the user an explanation before sending them to
     * settings for background location.
     *
     * True exactly while that is the outstanding step. Android 11 took "Allow
     * all the time" out of the runtime prompt — settings is the only route —
     * and requires an educational screen before the redirect. Below API 30 the
     * prompt still works, so there is nothing to explain and this is false.
     */
    fun needsBackgroundRationale(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            granted(context, Manifest.permission.ACCESS_FINE_LOCATION) &&
            !granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    /** Whether the device is in battery saver. */
    fun powerSaveMode(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java)?.isPowerSaveMode
            ?: false

    /**
     * Whether Android will leave this app alone when the screen is off. False
     * is where a background collector quietly loses its wake-ups to Doze.
     */
    fun ignoringBatteryOptimizations(context: Context): Boolean {
        val manager = context.getSystemService(PowerManager::class.java)
            ?: return false
        return manager.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Whether the fast movement detector is available to this session.
     *
     * Three answers, not two. Without Play Services there is no Activity
     * Recognition to ask for, and reporting that as `denied` would put a
     * button in the UI that cannot do anything. Below API 29 the permission is
     * install-time and always held.
     */
    fun motionPermissionName(context: Context): String {
        val available = GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
        if (!available) return "unavailable"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "granted"
        return if (granted(context, Manifest.permission.ACTIVITY_RECOGNITION)) {
            "granted"
        } else {
            "denied"
        }
    }

    fun locationEnabled(context: Context): Boolean {
        val manager =
            context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    fun map(
        context: Context,
        config: GeoConfigStore,
        queued: Int,
        activity: Activity? = null,
    ): Map<String, Any?> = mapOf(
        "is_tracking" to config.isTracking,
        "collector_running" to GeoTrackingService.isRunning,
        "permission" to permissionName(
            context, activity, config.permissionRequested
        ),
        "auth_failed" to config.authFailed,
        "queued_points" to queued,
        "location_services_enabled" to locationEnabled(context),
        // What the uploader would actually POST to, and how it last got on.
        // Between them these turn "the queue is not draining" from a question
        // into an answer — see `GeoTrackingStatus` on the Dart side.
        "upload_url" to config.url,
        "last_upload" to config.lastUpload,
        // The three ways a session can be granted, running, and still not
        // working. None of them is visible from any other field here.
        "precise_location" to preciseLocation(context),
        "needs_background_rationale" to needsBackgroundRationale(context),
        "power_save_mode" to powerSaveMode(context),
        "ignoring_battery_optimizations" to
            ignoringBatteryOptimizations(context),
        // Why the position has stopped changing, and why the track may start
        // two blocks late. Neither is visible from any other field.
        "is_moving" to config.isMoving,
        "motion_permission" to motionPermissionName(context),
    )
}
