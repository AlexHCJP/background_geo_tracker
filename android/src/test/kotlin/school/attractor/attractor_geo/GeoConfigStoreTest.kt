package school.attractor.attractor_geo

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
        "session_id" to "consent-42",
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
        assertEquals("", config.sessionId)
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
