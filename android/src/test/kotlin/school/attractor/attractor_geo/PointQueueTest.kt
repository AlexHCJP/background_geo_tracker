package school.attractor.attractor_geo

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import school.attractor.attractor_geo.db.GeoDatabase
import school.attractor.attractor_geo.db.PointQueue
import school.attractor.attractor_geo.db.PointRow

// The module compiles against SDK 36, which this Robolectric release has no
// runtime image for. SQLite behaviour we depend on is identical on 34.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PointQueueTest {
    private lateinit var db: GeoDatabase
    private lateinit var queue: PointQueue

    private val now = 1785665703000L
    private val day = 86_400_000L

    @Before
    fun setUp() {
        db = GeoDatabase.inMemory(ApplicationProvider.getApplicationContext())
        queue = PointQueue(db.points())
    }

    @After
    fun tearDown() = db.close()

    private fun row(
        id: String,
        atMillis: Long,
        sessionId: String = "consent-42",
    ) = PointRow(
        id = id,
        sessionId = sessionId,
        lat = 55.75,
        lon = 37.61,
        accuracy = 10.0,
        altitude = null,
        speed = null,
        heading = null,
        recordedAtMillis = atMillis,
        isMock = false,
        batteryLevel = null,
    )

    @Test
    fun `oldest returns points in recording order`() {
        queue.enqueue(row("c", now + 2), 100, 7)
        queue.enqueue(row("a", now), 100, 7)
        queue.enqueue(row("b", now + 1), 100, 7)

        assertEquals(listOf("a", "b", "c"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `oldest respects the batch limit`() {
        repeat(5) { queue.enqueue(row("p$it", now + it), 100, 7) }

        assertEquals(2, queue.oldest(2, now).size)
    }

    @Test
    fun `session query never returns another session's points`() {
        queue.enqueue(row("old", now, sessionId = "consent-old"), 100, 7)
        queue.enqueue(row("new", now + 1, sessionId = "consent-new"), 100, 7)

        assertEquals(
            listOf("new"),
            queue.oldestForSession("consent-new", 10).map { it.id },
        )
    }

    @Test
    fun `drop deletes only the acknowledged points`() {
        repeat(3) { queue.enqueue(row("p$it", now + it), 100, 7) }

        queue.drop(listOf("p0", "p1"))

        assertEquals(listOf("p2"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `the point ceiling evicts the oldest first`() {
        repeat(5) {
            queue.enqueue(row("p$it", now + it), maxPoints = 3, maxAgeDays = 7)
        }

        assertEquals(3, queue.count())
        assertEquals(listOf("p2", "p3", "p4"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `the age ceiling drops points older than the window`() {
        queue.enqueue(
            row("stale", now - 8 * day),
            maxPoints = 100,
            maxAgeDays = 7,
        )
        queue.enqueue(row("fresh", now), maxPoints = 100, maxAgeDays = 7)

        assertEquals(listOf("fresh"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `re-enqueuing the same id does not duplicate`() {
        queue.enqueue(row("p", now), 100, 7)
        queue.enqueue(row("p", now), 100, 7)

        assertEquals(1, queue.count())
    }

    @Test
    fun `clear empties the queue`() {
        queue.enqueue(row("a", now), 100, 7)
        queue.enqueue(row("b", now + 1), 100, 7)

        queue.clear()

        assertEquals(0, queue.count())
        assertEquals(emptyList<String>(), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `the queue is usable again after being cleared`() {
        queue.enqueue(row("old", now), 100, 7)
        queue.clear()
        queue.enqueue(row("new", now + 1), 100, 7)

        assertEquals(listOf("new"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `nullable sensor columns round-trip as null`() {
        queue.enqueue(row("p", now), 100, 7)

        val stored = queue.oldest(1, now).single()

        assertEquals(null, stored.altitude)
        assertEquals(null, stored.speed)
        assertEquals(null, stored.heading)
        assertEquals(null, stored.batteryLevel)
        assertEquals(55.75, stored.lat, 1e-9)
        assertEquals("consent-42", stored.sessionId)
    }

    @Test
    fun `a deferred point is not handed out until its time comes`() {
        queue.enqueue(row("a", now), 100, 7)

        queue.defer(listOf("a"), now + 60_000L)

        assertTrue(queue.oldest(10, now).isEmpty())
    }

    @Test
    fun `a deferred point comes back once its time has passed`() {
        queue.enqueue(row("a", now), 100, 7)
        queue.defer(listOf("a"), now + 60_000L)

        assertEquals(listOf("a"), queue.oldest(10, now + 60_001L).map { it.id })
    }

    @Test
    fun `deferring the head lets the points behind it through`() {
        // The whole reason deferral exists rather than dropping: the queue is
        // read from the head, so a batch that is never accepted would
        // otherwise be re-read forever and nothing behind it would move.
        queue.enqueue(row("stuck", now), 100, 7)
        queue.enqueue(row("fine", now + 1), 100, 7)

        queue.defer(listOf("stuck"), now + 60_000L)

        assertEquals(listOf("fine"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `defer touches only the ids it is given`() {
        queue.enqueue(row("a", now), 100, 7)
        queue.enqueue(row("b", now + 1), 100, 7)

        queue.defer(listOf("a"), now + 60_000L)

        assertEquals(listOf("b"), queue.oldest(10, now).map { it.id })
    }

    @Test
    fun `a second refusal moves the window rather than stacking it`() {
        queue.enqueue(row("a", now), 100, 7)

        queue.defer(listOf("a"), now + 60_000L)
        queue.defer(listOf("a"), now + 10_000L)

        // Overwritten, not added to: the point is due at the second deadline.
        assertEquals(listOf("a"), queue.oldest(10, now + 10_001L).map { it.id })
    }

    @Test
    fun `count includes deferred points`() {
        // The status answers "how much has not arrived yet", and a deferred
        // point has not arrived.
        queue.enqueue(row("a", now), 100, 7)
        queue.defer(listOf("a"), now + 60_000L)

        assertEquals(1, queue.count())
    }

    @Test
    fun `upgrading from version 1 keeps the queued points`() {
        // The cost of getting this wrong is not a red test — it is every
        // updating user's queue, silently deleted on the launch after an
        // update.
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file = context.getDatabasePath("migration_probe.db")
        file.parentFile?.mkdirs()
        file.delete()

        // A version-1 database, exactly as the shipped schema built it.
        val legacy = SQLiteDatabase.openOrCreateDatabase(file, null)
        legacy.execSQL(
            """
            CREATE TABLE points (
                id TEXT PRIMARY KEY NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                accuracy REAL NOT NULL,
                altitude REAL,
                speed REAL,
                heading REAL,
                recorded_at_millis INTEGER NOT NULL,
                is_mock INTEGER NOT NULL,
                battery_level REAL
            )
            """.trimIndent(),
        )
        legacy.execSQL(
            "INSERT INTO points " +
                "(id, lat, lon, accuracy, recorded_at_millis, is_mock) " +
                "VALUES ('survivor', 55.75, 37.61, 10.0, $now, 0)",
        )
        legacy.version = 1
        legacy.close()

        val upgraded = GeoDatabase.named(context, "migration_probe.db")
        val survivors = PointQueue(upgraded.points()).oldest(10, now)
        upgraded.close()

        assertEquals(listOf("survivor"), survivors.map { it.id })
    }
}
