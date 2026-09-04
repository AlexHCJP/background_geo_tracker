package dev.background_geo_tracker.plugin

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
        val config = GeoConfigStore(context)
        if (!config.isTracking || !config.isConfigured()) return
        if (!GeoStatus.hasBackgroundLocation(context)) return
        if (!GeoStatus.locationEnabled(context)) return
        runCatching { GeoTrackingService.start(context) }
    }
}
