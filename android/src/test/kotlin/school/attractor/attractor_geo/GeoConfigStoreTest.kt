package school.attractor.attractor_geo

import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

// The module compiles against SDK 36, which this Robolectric release has no
// runtime image for. Nothing exercised here changed between 34 and 36.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GeoConfigStoreTest {
    private lateinit var config: GeoConfigStore

    private val saved = mapOf<String, Any?>(
        "url" to "https://api.attractor.school/v1/tracking/points",
        "headers" to mapOf("Authorization" to "Bearer secret"),
        "distance_filter_meters" to 20,
        "min_interval_seconds" to 10,
        "batch_size" to 50,
        "upload_interval_seconds" to 60,
        "queue_max_points" to 20000,
        "queue_max_age_days" to 7,
        "notification_title" to "Tracking",
        "notification_body" to "Recording your route",
    )

    // The encrypted store cannot be built here: Robolectric has no
    // AndroidKeyStore. A plain one stands in — what is under test is which
    // keys survive a clear, not the encryption itself.
    @Before
    fun setUp() {
        config = GeoConfigStore(ApplicationProvider.getApplicationContext()) {
            it.getSharedPreferences("test_secure", Context.MODE_PRIVATE)
        }
    }

    @Test
    fun `the send threshold is stored apart from the batch size`() {
        config.save(saved + mapOf("send_after_points" to 1, "batch_size" to 50))

        // Freshness and request size are different questions: a point sends
        // immediately, a backlog still leaves fifty at a time.
        assertEquals(1, config.sendAfterPoints)
        assertEquals(50, config.batchSize)
    }

    @Test
    fun `a config saved before the threshold existed keeps the old behaviour`() {
        config.save(saved)

        assertEquals(config.batchSize, config.sendAfterPoints)
    }

    @Test
    fun `notification settings survive a save`() {
        config.save(
            saved + mapOf(
                "notification_title" to "Запись маршрута",
                "notification_body" to "Пишем ваш маршрут",
                "notification_channel_name" to "Запись маршрута",
                "notification_small_icon" to "ic_stat_route",
                "notification_importance" to "normal",
                "notification_tap_opens_app" to false,
            ),
        )

        assertEquals("Запись маршрута", config.notificationTitle)
        assertEquals("Пишем ваш маршрут", config.notificationBody)
        assertEquals("Запись маршрута", config.notificationChannelName)
        assertEquals("ic_stat_route", config.notificationSmallIcon)
        assertEquals(
            NotificationManager.IMPORTANCE_DEFAULT,
            config.notificationImportance,
        )
        assertFalse(config.notificationTapOpensApp)
    }

    @Test
    fun `a config saved before the notification object reads the defaults`() {
        // `notification_title` and `notification_body` kept their wire names
        // across the change, so only the four new keys can be missing here.
        config.save(saved)

        assertEquals("Tracking", config.notificationTitle)
        assertEquals("Location tracking", config.notificationChannelName)
        assertEquals("", config.notificationSmallIcon)
        assertEquals(
            NotificationManager.IMPORTANCE_LOW,
            config.notificationImportance,
        )
        assertTrue(config.notificationTapOpensApp)
    }

    @Test
    fun `an unknown importance name is read as the quiet one`() {
        // A name this build does not know must not make a long-running
        // session start making noise.
        config.save(saved + mapOf("notification_importance" to "screaming"))

        assertEquals(
            NotificationManager.IMPORTANCE_LOW,
            config.notificationImportance,
        )
    }

    @Test
    fun `motion settings survive a save`() {
        config.save(
            saved + mapOf(
                "motion_stop_timeout_seconds" to 60,
                "motion_stationary_radius_meters" to 200.0,
                "motion_elasticity_multiplier" to 0.0,
            ),
        )

        assertEquals(60, config.motionStopTimeoutSeconds)
        assertEquals(200.0, config.motionStationaryRadiusMeters, 1e-9)
        // Zero is a value, not an absent field: it means elasticity is off,
        // and falling back to 1.0 here would quietly switch it back on.
        assertEquals(0.0, config.motionElasticityMultiplier, 1e-9)
    }

    @Test
    fun `a config saved before motion existed reads the defaults`() {
        config.save(saved)

        assertEquals(300, config.motionStopTimeoutSeconds)
        assertEquals(150.0, config.motionStationaryRadiusMeters, 1e-9)
        assertEquals(1.0, config.motionElasticityMultiplier, 1e-9)
    }

    @Test
    fun `a session is moving until something says otherwise`() {
        assertTrue(config.isMoving)

        config.isMoving = false
        assertFalse(config.isMoving)
    }

    @Test
    fun `clear forgets the credentials`() {
        config.save(saved)
        assertEquals("Bearer secret", config.headers["Authorization"])

        config.clear()

        assertEquals(emptyMap<String, String>(), config.headers)
    }

    @Test
    fun `clear forgets the session and the endpoint`() {
        config.save(saved)
        config.isTracking = true
        config.authFailed = true

        config.clear()

        assertFalse(config.isConfigured())
        assertFalse(config.isTracking)
        assertFalse(config.authFailed)
        assertEquals("", config.url)
    }

    // Without this a signed-out device forgets it has ever shown the location
    // prompt, and a permanently denied permission starts reporting as one that
    // can still be asked for — so the UI offers a dialog the OS will not show.
    @Test
    fun `clear keeps what the device knows about the permission prompt`() {
        config.permissionRequested = true
        config.save(saved)

        config.clear()

        assertTrue(config.permissionRequested)
    }
}
