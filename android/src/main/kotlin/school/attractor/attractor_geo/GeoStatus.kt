package school.attractor.attractor_geo

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.core.app.ActivityCompat
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
    )
}
