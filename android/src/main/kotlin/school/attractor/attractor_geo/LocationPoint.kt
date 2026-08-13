package school.attractor.attractor_geo

import android.content.Context
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import java.util.UUID
import school.attractor.attractor_geo.db.PointRow

/**
 * The one place an Android [Location] becomes a point.
 *
 * Shared by the collector and by the one-shot read, which have to agree: a fix
 * that arrives through `currentPosition` and the same fix arriving a moment
 * later through the session must not differ in what they say about altitude,
 * speed or the battery.
 */
fun Location.toPointRow(context: Context): PointRow = PointRow(
    id = UUID.randomUUID().toString(),
    lat = latitude,
    lon = longitude,
    accuracy = accuracy.toDouble(),
    altitude = if (hasAltitude()) altitude else null,
    speed = if (hasSpeed()) speed.toDouble() else null,
    heading = if (hasBearing()) bearing.toDouble() else null,
    recordedAtMillis = time,
    isMock = isMockLocation(),
    batteryLevel = batteryLevel(context),
)

private fun Location.isMockLocation(): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        isMock
    } else {
        @Suppress("DEPRECATION")
        isFromMockProvider
    }

/** Fraction from 0.0 to 1.0, as the wire format requires. */
private fun batteryLevel(context: Context): Double? {
    val manager =
        context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
    val percent = manager.getIntProperty(
        BatteryManager.BATTERY_PROPERTY_CAPACITY,
    )
    return if (percent in 0..100) percent / 100.0 else null
}
