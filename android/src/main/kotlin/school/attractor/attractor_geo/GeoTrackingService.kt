package school.attractor.attractor_geo

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.net.ConnectivityManager
import android.net.Network
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
import school.attractor.attractor_geo.log.GeoLogDatabase
import school.attractor.attractor_geo.log.GeoLogStore
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
    private lateinit var logs: GeoLogStore

    /**
     * Wakes the drain the moment a network comes back.
     *
     * Not the same job as the worker's `NetworkType.CONNECTED` constraint,
     * which stays: that one keeps queued work from running without a network,
     * and this one says a network has appeared. WorkManager answers only the
     * first, and does it on the scheduler's timetable rather than now.
     */
    private var networks: ConnectivityManager.NetworkCallback? = null
    private lateinit var filter: LocationFilter
    private lateinit var policy: MotionPolicy
    private lateinit var detector: MotionDetector

    /**
     * Whether the state machine may run at all.
     *
     * Only under `Always`. Under `When In Use` a switched-off GPS would be a
     * session nobody can wake: the geofence needs background location, and the
     * app is by definition not on screen when it matters. Elasticity is not
     * gated on this — spacing points out by speed wakes nothing.
     */
    private val stopDetectionAllowed: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            GeoStatus.granted(
                this,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            )

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
        logs = GeoLogDatabase.open(this).store()
        watchNetwork()
        filter = LocationFilter(
            accuracyThresholdMeters = config.filterAccuracyThresholdMeters,
            minDisplacementMeters = config.filterMinDisplacementMeters,
            maxImpliedSpeedMps = config.filterMaxImpliedSpeedMps,
            kalmanProcessNoiseMps = config.filterKalmanProcessNoiseMps,
        )
        policy = MotionPolicy(
            stopTimeoutSeconds = config.motionStopTimeoutSeconds,
            stationaryRadiusMeters = config.motionStationaryRadiusMeters,
            elasticityMultiplier = config.motionElasticityMultiplier,
            baseDistanceFilterMeters = config.distanceFilterMeters.toDouble(),
        )
        detector = MotionDetector(this)
    }

    private fun watchNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Delivered on a binder thread, so the queue read is off the
                // main looper already.
                val queued = queue.count()
                logs.write(
                    System.currentTimeMillis(), "info", "connectivity.available",
                    "queue depth=$queued",
                )
                if (queued > 0) {
                    UploadWorker.enqueueNow(this@GeoTrackingService)
                }
            }
        }
        // Registration itself can throw on a device whose connectivity stack
        // is in a bad way; losing the trigger is survivable, losing the
        // collector is not.
        try {
            manager.registerDefaultNetworkCallback(callback)
            networks = callback
        } catch (e: SecurityException) {
            logs.write(
                System.currentTimeMillis(), "warning", "connectivity.available",
                "not watching: ${e.message ?: "registration refused"}",
            )
        }
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

        // Ahead of the wake branch below on purpose: the OS may have
        // restarted the service between the stop and the wake, and a
        // `location` service that collects without being in the foreground is
        // killed.
        startForeground(NOTIFICATION_ID, buildNotification())

        // A detector fired while the GPS was off. Nothing else about the
        // session changes — it was never stopped, only quietened.
        if (intent?.action == MotionDetector.ACTION_MOTION_WAKE &&
            wake(detector.sourceOf(intent))
        ) {
            return START_STICKY
        }
        // A wake that changed nothing means this is a fresh process: the OS
        // killed the service while it was stationary and the policy rebuilt in
        // `onCreate` already believes it is moving. Falling through opens the
        // session properly, where returning here would leave the service in
        // the foreground collecting nothing until the app was opened by hand.

        // The only place a reboot or an OS restart passes through, and no
        // Dart call comes with either of them.
        logs.write(
            System.currentTimeMillis(), "info", "session.resume",
            if (intent == null) "restarted by the OS" else "started by the app",
        )

        // A fresh session, or one resumed after the OS restarted us: the old
        // anchor may be a country away.
        policy.reset()
        config.isMoving = true
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
        // Left alone when it is already running. `onStartCommand` arrives on
        // every launch and every return to the foreground — the host re-sends
        // the endpoint and credentials then — and a loop rebuilt each time
        // starts its delay over, so a reader who keeps opening the app keeps
        // pushing away the very sweep they are waiting for.
        if (drains?.isActive != true) {
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
        // Whatever survived the last run has already waited; making it sit out
        // a fresh period while the app is open and on a network is the wrong
        // way round.
        if (queue.count() > 0) UploadWorker.enqueueNow(this)
    }

    private fun requestUpdates(
        distanceFilterMeters: Double = config.distanceFilterMeters.toDouble(),
    ) {
        val intervalMillis = config.minIntervalSeconds * 1000L
        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            intervalMillis,
        )
            .setMinUpdateDistanceMeters(distanceFilterMeters.toFloat())
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

    /**
     * Puts the collector to sleep: the GPS goes off, the detectors go on, and
     * the service stays exactly where it is.
     *
     * The service is deliberately not stopped. Its notification and its
     * foreground state are what let a detector deliver into it at all —
     * restarting a foreground service from the background is what Android 12
     * forbids — and the battery is spent by the GPS, not by an idle service.
     */
    private fun goStationary(decision: MotionPolicy.Decision.Stop) {
        client.removeLocationUpdates(callback)
        val armed = detector.arm(
            decision.anchorLat,
            decision.anchorLon,
            decision.radiusMeters,
        )
        config.isMoving = false
        logs.write(
            System.currentTimeMillis(), "info", "motion.stationary",
            "anchor=%.5f,%.5f r=%.0fm still=%ds armed=%s".format(
                decision.anchorLat,
                decision.anchorLon,
                decision.radiusMeters,
                decision.stillSeconds,
                armed.ifEmpty { "nothing" },
            ),
        )
        emitStatus()
    }

    /**
     * A detector fired: the GPS comes back and the detectors stand down.
     *
     * False when there was no transition to make — either the other detector
     * got here first, or this is a fresh process whose policy has never
     * stopped. `onStartCommand` needs to tell those apart from a real wake.
     */
    private fun wake(source: String): Boolean {
        if (!policy.onMovementDetected(System.currentTimeMillis())) return false
        detector.disarm()
        config.isMoving = true
        requestUpdates()
        logs.write(
            System.currentTimeMillis(), "info", "motion.moving", source,
        )
        emitStatus()
        return true
    }

    private fun record(location: Location) {
        // Filtered on the delivery thread, before anything else happens to the
        // fix: a rejected one must cost no database write, no event, and no
        // upload trigger. The filter is stateful and single-threaded by way of
        // this callback always arriving on the main looper.
        val verdict = filter.apply(
            lat = location.latitude,
            lon = location.longitude,
            accuracy = location.accuracy.toDouble(),
            recordedAtMillis = location.time,
        )
        if (verdict !is LocationFilter.Verdict.Accept) {
            logs.write(
                location.time, "info", "fix.rejected",
                (verdict as LocationFilter.Verdict.Reject).reason,
            )
            return
        }
        logs.write(
            location.time, "info", "fix.accepted",
            "%.5f,%.5f acc %.0f→%.0f".format(
                verdict.lat,
                verdict.lon,
                location.accuracy.toDouble(),
                verdict.accuracy,
            ),
        )

        // Fed the raw position, not the smoothed one, and only for fixes the
        // filter kept: a fix rejected for a 1 km accuracy radius says nothing
        // about where the device is, and letting it move the anchor would hold
        // the GPS on all night in a basement.
        val decision = policy.onFix(
            lat = location.latitude,
            lon = location.longitude,
            // A missing speed reads as no information, which leaves the filter
            // at its base. Passing a negative one through would read as motion
            // in reverse.
            speedMps = if (location.hasSpeed() && location.speed > 0) {
                location.speed.toDouble()
            } else {
                0.0
            },
            atMillis = location.time,
        )
        when (decision) {
            is MotionPolicy.Decision.Stop ->
                if (stopDetectionAllowed) {
                    // The fix that ended the session is still a real position
                    // and still goes into the track below; only the ones after
                    // it are the ones nobody asked for.
                    goStationary(decision)
                } else {
                    // Under `When In Use` the machine does not run, and the
                    // policy must not be left believing it does.
                    policy.onMovementDetected(location.time)
                }

            is MotionPolicy.Decision.Continue ->
                if (decision.stepChanged) {
                    // Changing the filter on Android means tearing the request
                    // down and building it again, which is why the policy
                    // reports steps rather than a value per fix.
                    client.removeLocationUpdates(callback)
                    requestUpdates(decision.steppedDistanceFilterMeters)
                    logs.write(
                        location.time, "info", "filter.elasticity",
                        "%.1fm/s → %.0fm".format(
                            location.speed.toDouble(),
                            decision.steppedDistanceFilterMeters,
                        ),
                    )
                }
        }

        val row = location.toPointRow(this).copy(
            lat = verdict.lat,
            lon = verdict.lon,
            accuracy = verdict.accuracy,
        )

        scope.launch {
            queue.enqueue(row, config.queueMaxPoints, config.queueMaxAgeDays)
            logs.write(
                row.recordedAtMillis, "info", "queue.enqueued",
                "${row.id} depth=${queue.count()}",
            )
            GeoEventBus.emitPoint(row.toEventMap())
            // The threshold, not the batch size: how fresh the stored
            // position is and how big a request gets are different questions.
            // The worker drains the whole queue once it runs, so a low
            // threshold does not shrink what a backlog leaves in.
            if (queue.count() >= config.sendAfterPoints) {
                UploadWorker.enqueueNow(this@GeoTrackingService)
            }
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Re-created on every start so a rename lands. Importance does not
            // land: once a channel exists Android lets only the user move it,
            // which is documented on `GeoNotificationConfig.importance`.
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    config.notificationChannelName,
                    config.notificationImportance,
                ),
            )
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(config.notificationTitle)
            .setContentText(config.notificationBody)
            .setSmallIcon(smallIconId())
            // Not configurable, and must not become so: an ongoing
            // notification is what Android requires of a foreground service
            // for the whole session.
            .setOngoing(true)

        if (config.notificationTapOpensApp) {
            launchIntent()?.let(builder::setContentIntent)
        }

        return builder.build()
    }

    /**
     * The host's own status-bar icon, by name, or the platform's pin.
     *
     * Looked up by name because a Dart layer has no way to hold a generated
     * resource id. A miss falls back and says so in the log rather than
     * throwing: `setSmallIcon` with an invalid id fails when the notification
     * is posted, and that takes the whole foreground service down — losing the
     * session over an icon.
     */
    private fun smallIconId(): Int {
        val name = config.notificationSmallIcon
        if (name.isEmpty()) return android.R.drawable.ic_menu_mylocation

        for (type in arrayOf("drawable", "mipmap")) {
            val id = resources.getIdentifier(name, type, packageName)
            if (id != 0) return id
        }

        logs.write(
            System.currentTimeMillis(), "warning", "notification.icon",
            "no drawable or mipmap named $name; using the platform's",
        )
        return android.R.drawable.ic_menu_mylocation
    }

    /**
     * Opens whatever the host declares as its launcher activity. Null when it
     * declares none, which is legal for an app that lives entirely in another
     * app's UI — then the notification is simply inert.
     */
    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return null
        return PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            // Immutable: nothing fills anything into this one, and Android 12
            // rejects a PendingIntent that declares neither.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    override fun onDestroy() {
        client.removeLocationUpdates(callback)
        detector.disarm()
        networks?.let {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(it)
        }
        networks = null
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
