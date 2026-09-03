package school.attractor.attractor_geo.log

import android.content.ContentValues
import android.database.sqlite.SQLiteOpenHelper

/**
 * The log's storage. Both ceilings are enforced on every write, so a device
 * nobody has opened in a month still keeps the file bounded.
 *
 * Must stay behaviourally identical to the Swift `GeoLogStore`.
 */
class GeoLogStore(private val helper: SQLiteOpenHelper) {

    fun write(atMillis: Long, level: String, event: String, message: String) {
        val values = ContentValues().apply {
            put("at_millis", atMillis)
            put("level", level)
            put("event", event)
            put("message", message)
        }
        helper.writableDatabase.insert(GeoLogDatabase.TABLE, null, values)

        // The cutoff is measured from the incoming entry rather than the wall
        // clock, so a device whose clock jumped cannot wipe a valid log.
        helper.writableDatabase.delete(
            GeoLogDatabase.TABLE,
            "at_millis < ?",
            arrayOf((atMillis - MAX_AGE_DAYS * DAY_MILLIS).toString()),
        )
        if (count() > MAX_ROWS) trimTo(MAX_ROWS)
    }

    /**
     * Oldest first, by id rather than by timestamp.
     *
     * The log records the order things happened in. A fix whose clock
     * disagrees with its neighbours is itself worth seeing where it arrived,
     * not sorted into a position that hides the disagreement.
     */
    fun read(limit: Int): List<GeoLogRow> =
        helper.readableDatabase.rawQuery(
            "SELECT id, at_millis, level, event, message FROM " +
                "${GeoLogDatabase.TABLE} ORDER BY id ASC LIMIT ?",
            arrayOf(limit.toString()),
        ).use { cursor ->
            val rows = mutableListOf<GeoLogRow>()
            while (cursor.moveToNext()) {
                rows += GeoLogRow(
                    id = cursor.getLong(0),
                    atMillis = cursor.getLong(1),
                    level = cursor.getString(2),
                    event = cursor.getString(3),
                    message = cursor.getString(4),
                )
            }
            rows
        }

    /**
     * Acknowledges everything up to and including [untilId].
     *
     * Bounded by id rather than emptying the table: entries written while the
     * reader was busy have been seen by nobody and must survive.
     */
    fun drop(untilId: Long) {
        helper.writableDatabase.delete(
            GeoLogDatabase.TABLE,
            "id <= ?",
            arrayOf(untilId.toString()),
        )
    }

    fun clear() {
        helper.writableDatabase.delete(GeoLogDatabase.TABLE, null, null)
    }

    fun count(): Int = helper.readableDatabase
        .rawQuery("SELECT COUNT(*) FROM ${GeoLogDatabase.TABLE}", null)
        .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    private fun trimTo(keep: Int) {
        helper.writableDatabase.execSQL(
            "DELETE FROM ${GeoLogDatabase.TABLE} WHERE id NOT IN (" +
                "SELECT id FROM ${GeoLogDatabase.TABLE} " +
                "ORDER BY id DESC LIMIT ?)",
            arrayOf<Any>(keep),
        )
    }

    companion object {
        /** Roughly five hours of walking at the collector's current settings. */
        const val MAX_ROWS = 2000
        const val MAX_AGE_DAYS = 3
        private const val DAY_MILLIS = 86_400_000L
    }
}
