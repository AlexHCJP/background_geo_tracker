package dev.background_geo_tracker.plugin

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import dev.background_geo_tracker.plugin.log.GeoLogDatabase
import dev.background_geo_tracker.plugin.log.GeoLogStore

/**
 * The Swift `GeoLogStoreTests` mirror these case for case. A change here that
 * is not made there is the two platforms drifting apart about what the log
 * keeps, which is what a shared shape exists to prevent.
 */
// The module compiles against SDK 36, which this Robolectric release has no
// runtime image for. SQLite behaviour we depend on is identical on 34.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GeoLogStoreTest {

    private lateinit var store: GeoLogStore

    @Before
    fun setUp() {
        store = GeoLogStore(
            GeoLogDatabase.inMemory(ApplicationProvider.getApplicationContext()),
        )
    }

    private fun write(atMillis: Long, message: String) =
        store.write(atMillis, "info", "fix.accepted", message)

    @Test
    fun `entries come back in insertion order`() {
        write(3_000L, "third")
        write(1_000L, "first")
        write(2_000L, "second")

        // By id, not by timestamp: the log records the order things happened
        // in, and a fix whose clock disagrees is itself worth seeing in place.
        assertEquals(
            listOf("third", "first", "second"),
            store.read(10).map { it.message },
        )
    }

    @Test
    fun `read respects the limit`() {
        repeat(5) { write(it.toLong(), "entry $it") }

        assertEquals(2, store.read(2).size)
    }

    @Test
    fun `read does not delete`() {
        write(1_000L, "kept")

        store.read(10)

        assertEquals(1, store.count())
    }

    @Test
    fun `drop leaves entries written after the read`() {
        // The whole point of the two-phase drain: anything the reader never
        // saw must survive its acknowledgement.
        write(1_000L, "drained")
        val seen = store.read(10)
        write(2_000L, "arrived while draining")

        store.drop(seen.last().id)

        assertEquals(
            listOf("arrived while draining"),
            store.read(10).map { it.message },
        )
    }

    @Test
    fun `the row ceiling evicts the oldest first`() {
        repeat(GeoLogStore.MAX_ROWS + 10) { write(it.toLong(), "entry $it") }

        assertEquals(GeoLogStore.MAX_ROWS, store.count())
        assertEquals("entry 10", store.read(1).first().message)
    }

    @Test
    fun `the age ceiling drops entries older than the window`() {
        val now = 10_000_000_000L
        val window = GeoLogStore.MAX_AGE_DAYS * 86_400_000L
        write(now - window - 1, "ancient")

        // Measured from the incoming entry, so a clock that jumped cannot wipe
        // a valid log — the same rule the point queue uses.
        write(now, "fresh")

        assertEquals(listOf("fresh"), store.read(10).map { it.message })
    }

    @Test
    fun `clear empties the log`() {
        write(1_000L, "gone")

        store.clear()

        assertTrue(store.read(10).isEmpty())
    }
}
