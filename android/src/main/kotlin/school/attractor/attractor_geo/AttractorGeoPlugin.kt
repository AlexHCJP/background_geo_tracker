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
                config.save(call.arguments as Map<String, Any?>)
                result.success(null)
            }

            "start" -> {
                // Starting the service without location permission would
                // crash it on Android 14+, so refuse here rather than let the
                // service die silently a moment later.
                if (!GeoStatus.hasForegroundLocation(context)) {
                    result.error(
                        "permission_denied",
                        "Location permission is required to start tracking",
                        null,
                    )
                } else {
                    config.isTracking = true
                    GeoTrackingService.start(context)
                    requestNotificationsIfMissing()
                    result.success(null)
                    emitStatus()
                }
            }

            "stop" -> {
                config.isTracking = false
                GeoTrackingService.stop(context)
                UploadWorker.cancel(context)
                result.success(null)
                emitStatus()
            }

            "reset" -> scope.launch {
                config.isTracking = false
                GeoTrackingService.stop(context)
                UploadWorker.cancel(context)
                withContext(Dispatchers.IO) {
                    PointQueue(GeoDatabase.open(context).points()).clear()
                }
                // Last, so nothing above can read credentials that are on
                // their way out.
                config.clear()
                result.success(null)
                GeoEventBus.emitStatus(currentStatus())
            }

            "status" -> scope.launch { result.success(currentStatus()) }

            "requestPermission" -> {
                requestNextPermission()
                result.success(permissionName())
            }

            "openSystemSettings" -> {
                openSettings()
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
            // Android 11+ ignores an in-app dialog for this one and requires a
            // trip to the settings screen.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                openSettings()
            } else {
                ActivityCompat.requestPermissions(
                    current,
                    arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                    REQUEST_CODE,
                )
            }
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
