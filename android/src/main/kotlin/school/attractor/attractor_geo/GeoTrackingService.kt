package school.attractor.attractor_geo

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import school.attractor.attractor_geo.db.GeoDatabase
import school.attractor.attractor_geo.db.PointQueue
import school.attractor.attractor_geo.db.PointRow
import school.attractor.attractor_geo.upload.PointJson
import school.attractor.attractor_geo.upload.UploadWorker

/**
 * The collector. Runs as a `location`-typed foreground service so Android
 * keeps it alive with the app backgrounded, and writes every fix straight to
 * the durable queue — never to memory, never through Dart.
 */
class GeoTrackingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var config: GeoConfigStore
    private lateinit var queue: PointQueue
    private lateinit var client: FusedLocationProviderClient
    private var drains: Job? = null

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.locations.forEach(::record)
        }
    }

    override fun onCreate() {
        super.onCreate()
        config = GeoConfigStore(this)
        queue = PointQueue(GeoDatabase.open(this).points())
        client = LocationServices.getFusedLocationProviderClient(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Order matters. On Android 14+ `startForeground` for a `location`
        // service throws SecurityException when the location permission is
        // missing, so this check has to happen first — and the queue is left
        // untouched, because whatever it already holds still needs uploading.
        if (!GeoStatus.hasForegroundLocation(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        requestUpdates()
        startDrainLoop()
        UploadWorker.schedule(this, config.uploadIntervalSeconds)
        // Not only for the app that asked: a session resumed after a reboot or
        // a low-memory kill starts here too, with no Dart call to report it.
        emitStatus()
        // START_STICKY so the OS restarts us after a low-memory kill.
        return START_STICKY
    }

    /**
     * Reads the queue depth on the calling thread deliberately. A coroutine
     * would not reliably run before the service is torn down, and teardown is
     * exactly when this matters most — one indexed COUNT over at most a few
     * days of points is the cheaper trade.
     */
    private fun emitStatus() {
        GeoEventBus.emitStatus(GeoStatus.map(this, config, queue.count()))
    }

    /**
     * Sends a half-full batch on `uploadIntervalSeconds`, the way the config
     * says it will.
     *
     * WorkManager cannot do this: its floor for periodic work is 15 minutes,
     * so on its own a phone sitting still under `batchSize` held its points
     * for a quarter of an hour while iOS shipped them in a minute — one
     * setting meaning two different things. This service is alive for the
     * whole session anyway, so it can keep that promise itself; the periodic
     * worker stays as the net for when it is not alive.
     *
     * The queue is checked first so an idle session is not paying WorkManager
     * to wake up and find nothing.
     */
    private fun startDrainLoop() {
        drains?.cancel()
        val period = config.uploadIntervalSeconds.coerceAtLeast(1) * 1000L
        drains = scope.launch {
            while (isActive) {
                delay(period)
                if (queue.count() > 0) {
                    UploadWorker.enqueueNow(this@GeoTrackingService)
                }
            }
        }
    }

    private fun requestUpdates() {
        val intervalMillis = config.minIntervalSeconds * 1000L
        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            intervalMillis,
        )
            .setMinUpdateDistanceMeters(config.distanceFilterMeters.toFloat())
            .setMinUpdateIntervalMillis(intervalMillis)
            .setWaitForAccurateLocation(false)
            .build()

        // Permission was checked in onStartCommand; it can still be revoked
        // from Settings mid-session, which arrives as a SecurityException here
        // on some OEM builds rather than a callback.
        try {
            client.requestLocationUpdates(request, callback, mainLooper)
        } catch (_: SecurityException) {
            stopSelf()
        }
    }

    private fun record(location: Location) {
        val row = location.toPointRow(this)

        scope.launch {
            queue.enqueue(row, config.queueMaxPoints, config.queueMaxAgeDays)
            GeoEventBus.emitPoint(row.toEventMap())
            if (queue.count() >= config.batchSize) {
                UploadWorker.enqueueNow(this@GeoTrackingService)
            }
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Location tracking",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(config.notificationTitle)
            .setContentText(config.notificationBody)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        client.removeLocationUpdates(callback)
        // Covers the stops nobody asked for: permission revoked from Settings
        // mid-session, or the OS shutting the service down. An explicit stop
        // reports itself from the plugin as well; a duplicate status is
        // harmless, a missing one is not.
        emitStatus()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "attractor_geo_tracking"
        private const val NOTIFICATION_ID = 4711

        fun start(context: Context) {
            val intent = Intent(context, GeoTrackingService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GeoTrackingService::class.java))
        }
    }
}

/** The event-channel shape, matching `GeoPoint.fromMap` on the Dart side. */
fun PointRow.toEventMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "lat" to lat,
    "lon" to lon,
    "accuracy" to accuracy,
    "altitude" to altitude,
    "speed" to speed,
    "heading" to heading,
    "recorded_at" to PointJson.timestamp(recordedAtMillis),
    "is_mock" to isMock,
    "battery_level" to batteryLevel,
)
