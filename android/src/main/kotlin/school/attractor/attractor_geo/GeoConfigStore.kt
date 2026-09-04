package school.attractor.attractor_geo

import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.net.URI
import org.json.JSONObject

/**
 * Everything the native tracker needs to keep working with no Dart isolate
 * alive: the upload policy, the auth headers, and whether a session is on.
 *
 * Headers hold a bearer token, so they live in encrypted preferences.
 */
class GeoConfigStore(
    context: Context,
    secureStore: (Context) -> SharedPreferences = ::encryptedPreferences,
) {

    private val app = context.applicationContext

    private val prefs: SharedPreferences =
        app.getSharedPreferences("attractor_geo", Context.MODE_PRIVATE)

    /**
     * Built lazily, and only ever swapped out by tests: the JVM has no
     * AndroidKeyStore, so [encryptedPreferences] cannot be constructed under
     * Robolectric at all. Production always gets the encrypted store.
     */
    private val securePrefs: SharedPreferences by lazy { secureStore(app) }

    /// The codec hands whole numbers over as Integer or Long depending on
    /// magnitude, so go through Number rather than casting straight to Int.
    private fun Map<String, Any?>.int(key: String, fallback: Int): Int =
        (this[key] as? Number)?.toInt() ?: fallback

    private fun Map<String, Any?>.string(key: String, fallback: String): String =
        this[key] as? String ?: fallback

    private fun Map<String, Any?>.double(key: String, fallback: Double): Double =
        (this[key] as? Number)?.toDouble() ?: fallback

    fun save(config: Map<String, Any?>) {
        validate(config)
        @Suppress("UNCHECKED_CAST")
        val headers = config["headers"] as Map<String, String>
        require(
            securePrefs.edit()
                .putString("headers", JSONObject(headers).toString())
                .commit()
        ) { "secure credential storage is unavailable" }

        prefs.edit().apply {
            putString("session_id", config.string("session_id", ""))
            putString("url", config.string("url", ""))
            putInt(
                "distance_filter_meters",
                config.int("distance_filter_meters", 20),
            )
            putInt(
                "min_interval_seconds",
                config.int("min_interval_seconds", 10),
            )
            putInt("batch_size", config.int("batch_size", 50))
            putInt(
                "send_after_points",
                config.int("send_after_points", config.int("batch_size", 50)),
            )
            putInt(
                "upload_interval_seconds",
                config.int("upload_interval_seconds", 60),
            )
            putInt("queue_max_points", config.int("queue_max_points", 20000))
            putInt("queue_max_age_days", config.int("queue_max_age_days", 7))
            putString(
                "notification_title",
                config.string("notification_title", "Tracking"),
            )
            putString(
                "notification_body",
                config.string("notification_body", "Recording your route"),
            )
            putString(
                "notification_channel_name",
                config.string("notification_channel_name", "Location tracking"),
            )
            putString(
                "notification_small_icon",
                config.string("notification_small_icon", ""),
            )
            putString(
                "notification_importance",
                config.string("notification_importance", "low"),
            )
            putBoolean(
                "notification_tap_opens_app",
                config["notification_tap_opens_app"] as? Boolean ?: true,
            )
            putFloat(
                "filter_accuracy_threshold_meters",
                config.double("filter_accuracy_threshold_meters", 100.0)
                    .toFloat(),
            )
            putFloat(
                "filter_min_displacement_meters",
                config.double("filter_min_displacement_meters", 1.0).toFloat(),
            )
            putFloat(
                "filter_max_implied_speed_mps",
                config.double("filter_max_implied_speed_mps", 60.0).toFloat(),
            )
            putFloat(
                "filter_kalman_process_noise_mps",
                config.double("filter_kalman_process_noise_mps", 3.0).toFloat(),
            )
            putInt(
                "motion_stop_timeout_seconds",
                config.int("motion_stop_timeout_seconds", 300),
            )
            putFloat(
                "motion_stationary_radius_meters",
                config.double("motion_stationary_radius_meters", 150.0)
                    .toFloat(),
            )
            putFloat(
                "motion_elasticity_multiplier",
                config.double("motion_elasticity_multiplier", 1.0).toFloat(),
            )
            putBoolean("configured", true)
        }.apply()

        // Fresh credentials are the recovery path out of a 401.
        authFailed = false
    }

    /**
     * Forgets the session and the credentials.
     *
     * [permissionRequested] deliberately survives: it records what this
     * *device* has been shown, not what the signed-out user did. Clearing it
     * would make a permanently denied permission look like one that has never
     * been asked for, and the UI would offer a prompt the OS will not show.
     */
    fun clear() {
        val everAsked = permissionRequested
        prefs.edit().clear().apply()
        securePrefs.edit().clear().apply()
        permissionRequested = everAsked
    }

    fun isConfigured(): Boolean = prefs.getBoolean("configured", false)

    val sessionId: String get() = prefs.getString("session_id", "")!!

    /**
     * The whole endpoint, as the Dart side wrote it down. Not assembled from
     * parts here — see `GeoUploadConfig.url`.
     */
    val url: String get() = prefs.getString("url", "")!!
    val distanceFilterMeters: Int
        get() = prefs.getInt("distance_filter_meters", 20)
    val minIntervalSeconds: Int get() = prefs.getInt("min_interval_seconds", 10)
    val batchSize: Int get() = prefs.getInt("batch_size", 50)

    /**
     * How many queued points make an arriving point send a request. Falls back
     * to [batchSize], which is what this used to be half of, so a store
     * written by an older build behaves exactly as it did.
     */
    val sendAfterPoints: Int
        get() = prefs.getInt("send_after_points", batchSize)
    val uploadIntervalSeconds: Int
        get() = prefs.getInt("upload_interval_seconds", 60)
    val queueMaxPoints: Int get() = prefs.getInt("queue_max_points", 20000)
    val queueMaxAgeDays: Int get() = prefs.getInt("queue_max_age_days", 7)
    val filterAccuracyThresholdMeters: Double
        get() = prefs.getFloat("filter_accuracy_threshold_meters", 100f)
            .toDouble()
    val filterMinDisplacementMeters: Double
        get() = prefs.getFloat("filter_min_displacement_meters", 1f).toDouble()
    val filterMaxImpliedSpeedMps: Double
        get() = prefs.getFloat("filter_max_implied_speed_mps", 60f).toDouble()
    val filterKalmanProcessNoiseMps: Double
        get() = prefs.getFloat("filter_kalman_process_noise_mps", 3f).toDouble()

    val motionStopTimeoutSeconds: Int
        get() = prefs.getInt("motion_stop_timeout_seconds", 300)
    val motionStationaryRadiusMeters: Double
        get() = prefs.getFloat("motion_stationary_radius_meters", 150f)
            .toDouble()
    val motionElasticityMultiplier: Double
        get() = prefs.getFloat("motion_elasticity_multiplier", 1f).toDouble()

    val notificationTitle: String
        get() = prefs.getString("notification_title", "Tracking")!!
    val notificationBody: String
        get() = prefs.getString("notification_body", "Recording your route")!!

    val notificationChannelName: String
        get() = prefs.getString("notification_channel_name", "Location tracking")!!

    /**
     * The name of a drawable in the host app's resources, or empty for the
     * platform's own. Resolved to an id in [GeoTrackingService], where a
     * `Resources` is at hand.
     */
    val notificationSmallIcon: String
        get() = prefs.getString("notification_small_icon", "")!!

    /**
     * Already translated to the platform constant, so no caller has to know
     * the mapping. An unknown name reads as [NotificationManager.IMPORTANCE_LOW]:
     * a session runs for hours, and a name this build does not understand must
     * not be what makes it start making noise.
     */
    val notificationImportance: Int
        get() = when (prefs.getString("notification_importance", "low")) {
            "normal" -> NotificationManager.IMPORTANCE_DEFAULT
            else -> NotificationManager.IMPORTANCE_LOW
        }

    val notificationTapOpensApp: Boolean
        get() = prefs.getBoolean("notification_tap_opens_app", true)

    val headers: Map<String, String>
        get() {
            val raw = securePrefs.getString("headers", null) ?: return emptyMap()
            val json = JSONObject(raw)
            return json.keys().asSequence().associateWith { json.getString(it) }
        }

    /** Persisted so a session survives process death and reboot. */
    var isTracking: Boolean
        get() = prefs.getBoolean("is_tracking", false)
        set(value) = prefs.edit().putBoolean("is_tracking", value).apply()

    /**
     * Whether the collector is currently asking for fixes. Persisted because
     * the status is assembled from places the service object cannot be reached
     * from — the plugin and the upload worker — and a status that reported a
     * stationary collector as collecting would explain nothing.
     *
     * True by default: a session that has never stopped is moving.
     */
    var isMoving: Boolean
        get() = prefs.getBoolean("is_moving", true)
        set(value) = prefs.edit().putBoolean("is_moving", value).apply()

    var authFailed: Boolean
        get() = prefs.getBoolean("auth_failed", false)
        set(value) = prefs.edit().putBoolean("auth_failed", value).apply()

    /**
     * How the last drain attempt ended. Persisted, so a drain that failed
     * while the app was closed is still there to read when it is next opened —
     * which, for a background uploader, is the only time anyone reads it.
     */
    var lastUpload: String
        get() = prefs.getString("last_upload", "never")!!
        set(value) = prefs.edit().putString("last_upload", value).apply()

    /**
     * Whether we have ever shown the location prompt. Distinguishes "not asked
     * yet" from "permanently denied", which the OS itself cannot tell apart.
     */
    var permissionRequested: Boolean
        get() = prefs.getBoolean("permission_requested", false)
        set(value) =
            prefs.edit().putBoolean("permission_requested", value).apply()

    private fun validate(value: Map<String, Any?>) {
        require(value.string("session_id", "").isNotBlank()) {
            "session_id must not be empty"
        }
        val endpoint = runCatching {
            URI(value.string("url", "").trim())
        }.getOrNull()
        require(
            endpoint?.scheme == "https" &&
                !endpoint.host.isNullOrBlank() &&
                endpoint.rawFragment == null
        ) { "url must be an absolute HTTPS URL without a fragment" }
        require(value.int("distance_filter_meters", -1) >= 0) {
            "distance_filter_meters must be zero or greater"
        }
        for (key in listOf(
            "min_interval_seconds",
            "batch_size",
            "upload_interval_seconds",
            "queue_max_points",
            "queue_max_age_days",
        )) {
            require(value.int(key, 0) > 0) { "$key must be greater than zero" }
        }
        @Suppress("UNCHECKED_CAST")
        val headers = requireNotNull(value["headers"] as? Map<String, String>) {
            "headers must be a string map"
        }
        require(headers.keys.none { it.isBlank() }) {
            "header names must not be empty"
        }
        require(value.string("notification_title", "").isNotBlank()) {
            "notification_title must not be empty"
        }
        require(value.string("notification_body", "").isNotBlank()) {
            "notification_body must not be empty"
        }
    }
}

/**
 * The real credential store. Headers hold a bearer token, so they live behind
 * a key the Android Keystore holds and this process cannot export.
 */
private fun encryptedPreferences(app: Context): SharedPreferences {
    val key = MasterKey.Builder(app)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    return EncryptedSharedPreferences.create(
        app,
        "attractor_geo_secure",
        key,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
}
