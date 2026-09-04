package dev.background_geo_tracker.plugin.db

/**
 * The durable point queue. Enforces both ceilings on every write so the
 * database stays bounded even if uploading has been failing for days.
 */
class PointQueue(private val dao: PointDao) {

    fun enqueue(point: PointRow, maxPoints: Int, maxAgeDays: Int) {
        dao.insert(point)
        // The cutoff is measured from the incoming point rather than the wall
        // clock, so a device whose clock jumped cannot wipe a valid queue.
        dao.deleteOlderThan(point.recordedAtMillis - maxAgeDays * DAY_MILLIS)
        if (dao.count() > maxPoints) {
            dao.trimTo(maxPoints)
        }
    }

    fun oldest(limit: Int, nowMillis: Long): List<PointRow> =
        dao.oldest(limit, nowMillis)

    /** Stands a refused batch down so the queue behind it can move. */
    fun defer(ids: List<String>, untilMillis: Long) =
        dao.defer(ids, untilMillis)

    fun oldestForSession(sessionId: String, limit: Int): List<PointRow> =
        dao.oldestForSession(sessionId, limit)

    fun drop(ids: List<String>) = dao.deleteByIds(ids)

    fun count(): Int = dao.count()

    fun countForSession(sessionId: String): Int = dao.countForSession(sessionId)

    /**
     * Throws the whole queue away. For signing out: these points belong to
     * whoever recorded them, and must not be uploaded by the next account on
     * this device.
     */
    fun clear() = dao.deleteAll()

    private companion object {
        const val DAY_MILLIS = 86_400_000L
    }
}
