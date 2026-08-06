package school.attractor.attractor_geo

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
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

    fun save(config: Map<String, Any?>) {
        prefs.edit().apply {
            putString("base_url", config.string("base_url", ""))
            putString("path", config.string("path", ""))
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
            putBoolean("configured", true)
        }.apply()

        @Suppress("UNCHECKED_CAST")
        val headers = config["headers"] as Map<String, String>
        securePrefs.edit()
            .putString("headers", JSONObject(headers).toString())
            .apply()

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

    val baseUrl: String get() = prefs.getString("base_url", "")!!
    val path: String get() = prefs.getString("path", "")!!
    val distanceFilterMeters: Int
        get() = prefs.getInt("distance_filter_meters", 20)
    val minIntervalSeconds: Int get() = prefs.getInt("min_interval_seconds", 10)
    val batchSize: Int get() = prefs.getInt("batch_size", 50)
    val uploadIntervalSeconds: Int
        get() = prefs.getInt("upload_interval_seconds", 60)
    val queueMaxPoints: Int get() = prefs.getInt("queue_max_points", 20000)
    val queueMaxAgeDays: Int get() = prefs.getInt("queue_max_age_days", 7)
    val notificationTitle: String
        get() = prefs.getString("notification_title", "Tracking")!!
    val notificationBody: String
        get() = prefs.getString("notification_body", "Recording your route")!!

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

    var authFailed: Boolean
        get() = prefs.getBoolean("auth_failed", false)
        set(value) = prefs.edit().putBoolean("auth_failed", value).apply()

    /**
     * Whether we have ever shown the location prompt. Distinguishes "not asked
     * yet" from "permanently denied", which the OS itself cannot tell apart.
     */
    var permissionRequested: Boolean
        get() = prefs.getBoolean("permission_requested", false)
        set(value) =
            prefs.edit().putBoolean("permission_requested", value).apply()
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
