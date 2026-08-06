package school.attractor.attractor_geo

import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
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

    private fun row(id: String, atMillis: Long) = PointRow(
        id = id,
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

        assertEquals(listOf("a", "b", "c"), queue.oldest(10).map { it.id })
    }

    @Test
    fun `oldest respects the batch limit`() {
        repeat(5) { queue.enqueue(row("p$it", now + it), 100, 7) }

        assertEquals(2, queue.oldest(2).size)
    }

    @Test
    fun `drop deletes only the acknowledged points`() {
        repeat(3) { queue.enqueue(row("p$it", now + it), 100, 7) }

        queue.drop(listOf("p0", "p1"))

        assertEquals(listOf("p2"), queue.oldest(10).map { it.id })
    }

    @Test
    fun `the point ceiling evicts the oldest first`() {
        repeat(5) {
            queue.enqueue(row("p$it", now + it), maxPoints = 3, maxAgeDays = 7)
        }

        assertEquals(3, queue.count())
        assertEquals(listOf("p2", "p3", "p4"), queue.oldest(10).map { it.id })
    }

    @Test
    fun `the age ceiling drops points older than the window`() {
        queue.enqueue(
            row("stale", now - 8 * day),
            maxPoints = 100,
            maxAgeDays = 7,
        )
        queue.enqueue(row("fresh", now), maxPoints = 100, maxAgeDays = 7)

        assertEquals(listOf("fresh"), queue.oldest(10).map { it.id })
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
        assertEquals(emptyList<String>(), queue.oldest(10).map { it.id })
    }

    @Test
    fun `the queue is usable again after being cleared`() {
        queue.enqueue(row("old", now), 100, 7)
        queue.clear()
        queue.enqueue(row("new", now + 1), 100, 7)

        assertEquals(listOf("new"), queue.oldest(10).map { it.id })
    }

    @Test
    fun `nullable sensor columns round-trip as null`() {
        queue.enqueue(row("p", now), 100, 7)

        val stored = queue.oldest(1).single()

        assertEquals(null, stored.altitude)
        assertEquals(null, stored.speed)
        assertEquals(null, stored.heading)
        assertEquals(null, stored.batteryLevel)
        assertEquals(55.75, stored.lat, 1e-9)
    }
}
