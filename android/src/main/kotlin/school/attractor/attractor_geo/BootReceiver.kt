package school.attractor.attractor_geo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restores an active session after a reboot. A user-initiated force-stop is
 * not recoverable this way — Android delivers no broadcast until the app is
 * launched by hand again.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!GeoConfigStore(context).isTracking) return
        GeoTrackingService.start(context)
    }
}
