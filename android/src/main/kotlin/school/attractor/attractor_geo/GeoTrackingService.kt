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
                val queued = queue.count()

                logs.write(
                    System.currentTimeMillis(),
                    "info",
                    "connectivity.available",
                    "queue depth=$queued",
                )

                if (queued > 0) {
                    UploadWorker.enqueueNow(this@GeoTrackingService)
                }
            }
        }

        try {
            manager.registerDefaultNetworkCallback(callback)
            networks = callback
        } catch (e: SecurityException) {
            logs.write(
                System.currentTimeMillis(),
                "warning",
                "connectivity.available",
                "not watching: ${e.message ?: "registration refused"}",
            )
        }
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (!config.isConfigured() ||
            !GeoStatus.hasBackgroundLocation(this) ||
            !GeoStatus.locationEnabled(this)
        ) {
            isRunning = false
            stopSelf()

            return START_NOT_STICKY
        }

        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
        )

        isRunning = true

        if (intent?.action == MotionDetector.ACTION_MOTION_WAKE &&
            wake(detector.sourceOf(intent))
        ) {
            return START_STICKY
        }

        logs.write(
            System.currentTimeMillis(),
            "info",
            "session.resume",
            if (intent == null) {
                "restarted by the OS"
            } else {
                "started by the app"
            },
        )

        policy.reset()
        config.isMoving = true

        requestUpdates()
        startDrainLoop()

        UploadWorker.schedule(
            this,
            config.uploadIntervalSeconds,
        )

        emitStatus()

        return START_STICKY
    }

    /**
     * Reads the queue depth on the calling thread deliberately. A coroutine
     * would not reliably run before the service is torn down.
     */
    private fun emitStatus() {
        GeoEventBus.emitStatus(
            GeoStatus.map(
                this,
                config,
                queue.count(),
            ),
        )
    }

    /**
     * Sends a half-full batch on `uploadIntervalSeconds`.
     */
    private fun startDrainLoop() {
        if (drains?.isActive != true) {
            val period =
                config.uploadIntervalSeconds.coerceAtLeast(1) * 1000L

            drains = scope.launch {
                while (isActive) {
                    delay(period)

                    if (queue.count() > 0) {
                        UploadWorker.enqueueNow(
                            this@GeoTrackingService,
                        )
                    }
                }
            }
        }

        if (queue.count() > 0) {
            UploadWorker.enqueueNow(this)
        }
    }

    private fun requestUpdates(
        distanceFilterMeters: Double =
            config.distanceFilterMeters.toDouble(),
    ) {
        val intervalMillis =
            config.minIntervalSeconds * 1000L

        val request = LocationRequest.Builder(
            Priority.PRIORITY_HIGH_ACCURACY,
            intervalMillis,
        )
            .setMinUpdateDistanceMeters(
                distanceFilterMeters.toFloat(),
            )
            .setMinUpdateIntervalMillis(intervalMillis)
            .setWaitForAccurateLocation(false)
            .build()

        try {
            client.requestLocationUpdates(
                request,
                callback,
                mainLooper,
            )
        } catch (_: SecurityException) {
            stopSelf()
        }
    }

    /**
     * Puts the collector to sleep: the GPS goes off, the detectors go on.
     */
    private fun goStationary(
        decision: MotionPolicy.Decision.Stop,
    ) {
        client.removeLocationUpdates(callback)

        val armed = detector.arm(
            decision.anchorLat,
            decision.anchorLon,
            decision.radiusMeters,
        )

        config.isMoving = false

        logs.write(
            System.currentTimeMillis(),
            "info",
            "motion.stationary",
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
     */
    private fun wake(source: String): Boolean {
        if (!policy.onMovementDetected(System.currentTimeMillis())) {
            return false
        }

        detector.disarm()

        config.isMoving = true

        requestUpdates()

        logs.write(
            System.currentTimeMillis(),
            "info",
            "motion.moving",
            source,
        )

        emitStatus()

        return true
    }

    private fun record(location: Location) {
        val verdict = filter.apply(
            lat = location.latitude,
            lon = location.longitude,
            accuracy = location.accuracy.toDouble(),
            recordedAtMillis = location.time,
        )

        if (verdict !is LocationFilter.Verdict.Accept) {
            logs.write(
                location.time,
                "info",
                "fix.rejected",
                (verdict as LocationFilter.Verdict.Reject).reason,
            )

            return
        }

        logs.write(
            location.time,
            "info",
            "fix.accepted",
            "%.5f,%.5f acc %.0f→%.0f".format(
                verdict.lat,
                verdict.lon,
                location.accuracy.toDouble(),
                verdict.accuracy,
            ),
        )

        val decision = policy.onFix(
            lat = location.latitude,
            lon = location.longitude,
            speedMps =
                if (location.hasSpeed() && location.speed > 0) {
                    location.speed.toDouble()
                } else {
                    0.0
                },
            atMillis = location.time,
        )

        when (decision) {
            is MotionPolicy.Decision.Stop -> {
                if (stopDetectionAllowed) {
                    goStationary(decision)
                } else {
                    policy.onMovementDetected(location.time)
                }
            }

            is MotionPolicy.Decision.Continue -> {
                if (decision.stepChanged) {
                    client.removeLocationUpdates(callback)

                    requestUpdates(
                        decision.steppedDistanceFilterMeters,
                    )

                    logs.write(
                        location.time,
                        "info",
                        "filter.elasticity",
                        "%.1fm/s → %.0fm".format(
                            location.speed.toDouble(),
                            decision.steppedDistanceFilterMeters,
                        ),
                    )
                }
            }
        }

        val row = location
            .toPointRow(
                this,
                config.sessionId,
            )
            .copy(
                lat = verdict.lat,
                lon = verdict.lon,
                accuracy = verdict.accuracy,
            )

        scope.launch {
            queue.enqueue(
                row,
                config.queueMaxPoints,
                config.queueMaxAgeDays,
            )

            logs.write(
                row.recordedAtMillis,
                "info",
                "queue.enqueued",
                "${row.id} depth=${queue.count()}",
            )

            GeoEventBus.emitPoint(
                row.toEventMap(),
            )

            if (queue.count() >= config.sendAfterPoints) {
                UploadWorker.enqueueNow(
                    this@GeoTrackingService,
                )
            }
        }
    }

    private fun buildNotification(): Notification {
        val manager =
            getSystemService(NotificationManager::class.java)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    config.notificationChannelName,
                    config.notificationImportance,
                ),
            )
        }

        val builder =
            NotificationCompat.Builder(
                this,
                CHANNEL_ID,
            )
                .setContentTitle(
                    config.notificationTitle,
                )
                .setContentText(
                    config.notificationBody,
                )
                .setSmallIcon(smallIconId())
                .setOngoing(true)

        if (config.notificationTapOpensApp) {
            launchIntent()?.let(
                builder::setContentIntent,
            )
        }

        return builder.build()
    }

    private fun smallIconId(): Int {
        val name = config.notificationSmallIcon

        if (name.isEmpty()) {
            return android.R.drawable.ic_menu_mylocation
        }

        for (type in arrayOf("drawable", "mipmap")) {
            val id =
                resources.getIdentifier(
                    name,
                    type,
                    packageName,
                )

            if (id != 0) {
                return id
            }
        }

        logs.write(
            System.currentTimeMillis(),
            "warning",
            "notification.icon",
            "no drawable or mipmap named $name; using the platform's",
        )

        return android.R.drawable.ic_menu_mylocation
    }

    private fun launchIntent(): PendingIntent? {
        val intent =
            packageManager.getLaunchIntentForPackage(
                packageName,
            ) ?: return null

        return PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE,
        )
    }

    override fun onDestroy() {
        client.removeLocationUpdates(callback)

        isRunning = false

        detector.disarm()

        networks?.let {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(it)
        }

        networks = null

        emitStatus()

        scope.cancel()

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID =
            "attractor_geo_tracking"

        private const val NOTIFICATION_ID = 4711

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(
                context,
                GeoTrackingService::class.java,
            )

            ContextCompat.startForegroundService(
                context,
                intent,
            )
        }

        fun stop(context: Context) {
            context.stopService(
                Intent(
                    context,
                    GeoTrackingService::class.java,
                ),
            )
        }
    }
}

/** The event-channel shape, matching `GeoPoint.fromMap` on the Dart side. */
fun PointRow.toEventMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "session_id" to sessionId,
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