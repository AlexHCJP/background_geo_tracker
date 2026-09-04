package school.attractor.attractor_geo

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import school.attractor.attractor_geo.db.GeoDatabase
import school.attractor.attractor_geo.db.PointQueue
import school.attractor.attractor_geo.log.GeoLogDatabase
import school.attractor.attractor_geo.log.GeoLogRow
import school.attractor.attractor_geo.upload.UploadWorker

class AttractorGeoPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var points: EventChannel
    private lateinit var statuses: EventChannel
    private lateinit var config: GeoConfigStore
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        config = GeoConfigStore(context)

        methods = MethodChannel(binding.binaryMessenger, "school.attractor/geo")
        methods.setMethodCallHandler(this)

        points = EventChannel(
            binding.binaryMessenger,
            "school.attractor/geo/points",
        )
        points.setStreamHandler(
            handler(
                attach = { sink -> GeoEventBus.onPoint = sink },
                detach = { GeoEventBus.onPoint = null },
            ),
        )

        statuses = EventChannel(
            binding.binaryMessenger,
            "school.attractor/geo/status",
        )
        statuses.setStreamHandler(
            handler(
                attach = { sink -> GeoEventBus.onStatus = sink },
                detach = { GeoEventBus.onStatus = null },
            ),
        )
    }

    private fun handler(
        attach: ((Map<String, Any?>) -> Unit) -> Unit,
        detach: () -> Unit,
    ) = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            val sink = events ?: return
            attach { value -> sink.success(value) }
        }

        override fun onCancel(arguments: Any?) = detach()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                @Suppress("UNCHECKED_CAST")
                val arguments = call.arguments as? Map<String, Any?>
                if (arguments == null) {
                    result.error("bad_arguments", "configure expects a map", null)
                    return
                }

                val requestedSession = arguments["session_id"] as? String ?: ""
                if (config.isTracking && requestedSession != config.sessionId) {
                    result.error(
                        "session_active",
                        "Stop the active tracking session before configuring another one",
                        null,
                    )
                    return
                }

                try {
                    config.save(arguments)

                    GeoLogDatabase.open(context).store().write(
                        System.currentTimeMillis(),
                        "info",
                        "config.saved",
                        // The URL only. `config.headers` carries a bearer token
                        // and must never reach the log in any form.
                        "url=${config.url}",
                    )

                    result.success(null)
                } catch (error: IllegalArgumentException) {
                    result.error("invalid_config", error.message, null)
                }
            }

            "start" -> {
                // Starting the service without location permission would
                // crash it on Android 14+, so refuse here rather than let the
                // service die silently a moment later.
                if (!config.isConfigured()) {
                    result.error(
                        "not_configured",
                        "Configure a tracking session before starting it",
                        null,
                    )
                } else if (!GeoStatus.hasBackgroundLocation(context)) {
                    result.error(
                        "background_permission_required",
                        "Always allow location access before starting tracking",
                        null,
                    )
                } else if (!GeoStatus.locationEnabled(context)) {
                    result.error(
                        "location_services_disabled",
                        "Turn on device location services before starting tracking",
                        null,
                    )
                } else {
                    try {
                        config.isTracking = true
                        GeoTrackingService.start(context)

                        requestNotificationsIfMissing()
                        requestActivityRecognitionIfMissing()

                        GeoLogDatabase.open(context).store().write(
                            System.currentTimeMillis(),
                            "info",
                            "session.start",
                            "${permissionName()} " +
                                "precise=${GeoStatus.preciseLocation(context)}",
                        )

                        result.success(null)
                        emitStatus()
                    } catch (error: RuntimeException) {
                        config.isTracking = false

                        result.error(
                            "start_failed",
                            error.message ?: "Native location service could not start",
                            null,
                        )

                        emitStatus()
                    }
                }
            }

            "stop" -> {
                config.isTracking = false
                GeoTrackingService.stop(context)
                UploadWorker.cancelPeriodic(context)
                UploadWorker.enqueueNow(context)
                GeoLogDatabase.open(context).store().write(
                    System.currentTimeMillis(), "info", "session.stop",
                    "asked by the app",
                )
                result.success(null)
                emitStatus()
            }

            "reset" -> scope.launch {
                config.isTracking = false
                GeoTrackingService.stop(context)
                UploadWorker.cancelAll(context)
                withContext(Dispatchers.IO) {
                    PointQueue(GeoDatabase.open(context).points()).clear()
                    // The entries carry coordinates, and those belong to
                    // whoever recorded them.
                    GeoLogDatabase.open(context).store().clear()
                }
                // Last, so nothing above can read credentials that are on
                // their way out.
                config.clear()
                result.success(null)
                GeoEventBus.emitStatus(currentStatus())
            }

            "status" -> scope.launch { result.success(currentStatus()) }

            "currentPosition" -> {
                val timeout = call.argument<Int>("timeout_seconds") ?: 10
                // The only call here that answers later. Play Services
                // delivers on the main thread, which is where `result` has to
                // be called from.
                OneShotLocation.request(context, timeout) { location ->
                    result.success(
                        location?.toPointRow(context, config.sessionId)?.toEventMap()
                    )
                }
            }

            "requestPermission" -> {
                requestNextPermission()
                result.success(permissionName())
            }

            "readLog" -> scope.launch {
                val limit = call.argument<Int>("limit") ?: 500
                val rows = withContext(Dispatchers.IO) {
                    GeoLogDatabase.open(context).store().read(limit)
                }
                result.success(rows.map { it.toEventMap() })
            }

            "dropLog" -> scope.launch {
                // Number, not Int: the codec hands whole numbers over as
                // Integer or Long depending on magnitude, and an autoincrement
                // id outgrows Int.
                val untilId = call.argument<Number>("until_id")?.toLong() ?: 0L
                withContext(Dispatchers.IO) {
                    GeoLogDatabase.open(context).store().drop(untilId)
                }
                result.success(null)
            }

            "openSystemSettings" -> {
                openSettings()
                result.success(null)
            }

            "openBatteryOptimizationSettings" -> {
                openBatteryOptimizationSettings()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private suspend fun currentStatus(): Map<String, Any?> {
        val queued = withContext(Dispatchers.IO) {
            PointQueue(GeoDatabase.open(context).points()).count()
        }
        return GeoStatus.map(context, config, queued, activity)
    }

    private fun permissionName(): String = GeoStatus.permissionName(
        context, activity, config.permissionRequested
    )

    /**
     * Pushes the current status onto the stream.
     *
     * Everything that changes what the status says goes through here, because
     * the alternative is a UI that only learns the truth when something
     * happens to call `status()`. The iOS side reports every one of these
     * transitions, and a stream that fires on one platform and not the other
     * is worse than no stream at all.
     */
    private fun emitStatus() {
        scope.launch { GeoEventBus.emitStatus(currentStatus()) }
    }

    /**
     * Android 13 and later will not show the foreground service's notification
     * without this, and the OS requires that notification to be visible for
     * the whole session. Refusing it does not stop the service, so this asks
     * and moves on rather than gating the session on the answer.
     *
     * Asked at `start` rather than alongside the location prompt so that a
     * user who granted location before this existed is still asked once.
     */
    private fun requestNotificationsIfMissing() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val current = activity ?: return
        if (GeoStatus.granted(context, Manifest.permission.POST_NOTIFICATIONS)) {
            return
        }
        ActivityCompat.requestPermissions(
            current,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE,
        )
    }

    /**
     * The fast half of stop detection, asked for at `start` alongside
     * notifications.
     *
     * Refusing it does not stop anything: the geofence still wakes a
     * stationary collector, roughly 200 m later. Asked here rather than with
     * the location prompt so a user who granted location before this existed
     * is still asked once.
     */
    private fun requestActivityRecognitionIfMissing() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val current = activity ?: return
        if (GeoStatus.granted(
                context,
                Manifest.permission.ACTIVITY_RECOGNITION,
            )
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            current,
            arrayOf(Manifest.permission.ACTIVITY_RECOGNITION),
            REQUEST_CODE,
        )
    }

    /**
     * The answer to a permission dialog is the single most important thing the
     * status stream can carry: it is the moment a refused session becomes a
     * possible one. Without this the app has to poll to notice.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        GeoLogDatabase.open(context).store().write(
            System.currentTimeMillis(), "warning", "permission.changed",
            permissionName(),
        )
        if (permissions.contains(Manifest.permission.ACTIVITY_RECOGNITION)) {
            // The one permission whose refusal is invisible everywhere else:
            // the session runs, the track is written, and it simply starts two
            // blocks from where the walk did.
            GeoLogDatabase.open(context).store().write(
                System.currentTimeMillis(), "warning", "motion.permission",
                GeoStatus.motionPermissionName(context),
            )
        }
        emitStatus()
        return true
    }

    /**
     * Escalates exactly one step. Asking for background before foreground is
     * granted is rejected outright by Android 11 and later.
     */
    private fun requestNextPermission() {
        val current = activity ?: return
        val fine = GeoStatus.granted(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        )

        if (!fine) {
            // Recorded before the prompt, so a later "not granted" can be told
            // apart from "never asked".
            config.permissionRequested = true
            ActivityCompat.requestPermissions(
                current,
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                REQUEST_CODE,
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            !GeoStatus.granted(
                context, Manifest.permission.ACCESS_BACKGROUND_LOCATION
            )
        ) {
            // Android 11+ ignores an in-app dialog for this one and requires
            // a trip to the settings screen — which this deliberately does not
            // take on the user's behalf any more. Being thrown into system
            // settings by a button labelled "allow in background", with no
            // explanation of what to do once there, is the exact experience
            // Google's rationale requirement exists to prevent. The status
            // reports `needs_background_rationale` instead, and the app
            // explains and then calls `openSystemSettings` itself.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return
            } else {
                ActivityCompat.requestPermissions(
                    current,
                    arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                    REQUEST_CODE,
                )
            }
        }
    }

    /**
     * The battery-optimisation *list*, not the one-tap allow dialog.
     *
     * `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` would be one tap instead
     * of several, but it needs the permission of the same name — and a plugin
     * cannot quietly add a permission that Play review asks every host app to
     * justify. This intent needs nothing.
     */
    private fun openBatteryOptimizationSettings() {
        val intent = Intent(
            Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Not every build ships the screen; falling back to the app's own page
        // beats an ActivityNotFoundException out of a fire-and-forget call.
        try {
            context.startActivity(intent)
        } catch (_: android.content.ActivityNotFoundException) {
            openSettings()
        }
    }

    private fun openSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        points.setStreamHandler(null)
        statuses.setStreamHandler(null)
        GeoEventBus.onPoint = null
        GeoEventBus.onStatus = null
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onReattachedToActivityForConfigChanges(
        binding: ActivityPluginBinding,
    ) {
        attach(binding)
    }

    override fun onDetachedFromActivity() {
        detach()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    private fun attach(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        resumeCollectorIfPossible()
    }

    /** Restores a desired session after a force-stop followed by a manual open. */
    private fun resumeCollectorIfPossible() {
        if (!config.isTracking || GeoTrackingService.isRunning) return
        if (!config.isConfigured() ||
            !GeoStatus.hasBackgroundLocation(context) ||
            !GeoStatus.locationEnabled(context)
        ) {
            emitStatus()
            return
        }
        runCatching { GeoTrackingService.start(context) }
            .onFailure { emitStatus() }
    }

    private fun detach() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    private companion object {
        const val REQUEST_CODE = 4712
    }
}

/** The wire shape, matching `GeoLogEntry.fromMap` on the Dart side. */
fun GeoLogRow.toEventMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "at_millis" to atMillis,
    "level" to level,
    "event" to event,
    "message" to message,
)
