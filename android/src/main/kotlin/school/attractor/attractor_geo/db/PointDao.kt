package school.attractor.attractor_geo.db

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteOpenHelper

/** Every SQL statement the queue needs, and nothing else. */
class PointDao(private val helper: SQLiteOpenHelper) {

    fun insert(point: PointRow) {
        val values = ContentValues().apply {
            put("id", point.id)
            put("lat", point.lat)
            put("lon", point.lon)
            put("accuracy", point.accuracy)
            put("altitude", point.altitude)
            put("speed", point.speed)
            put("heading", point.heading)
            put("recorded_at_millis", point.recordedAtMillis)
            put("is_mock", if (point.isMock) 1 else 0)
            put("battery_level", point.batteryLevel)
        }
        helper.writableDatabase.insertWithOnConflict(
            GeoDatabase.TABLE,
            null,
            values,
            android.database.sqlite.SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun oldest(limit: Int): List<PointRow> {
        val cursor = helper.readableDatabase.rawQuery(
            "SELECT * FROM ${GeoDatabase.TABLE} " +
                "ORDER BY recorded_at_millis ASC LIMIT ?",
            arrayOf(limit.toString()),
        )
        return cursor.use { it.readAll() }
    }

    fun deleteByIds(ids: List<String>) {
        if (ids.isEmpty()) return
        val placeholders = ids.joinToString(",") { "?" }
        helper.writableDatabase.delete(
            GeoDatabase.TABLE,
            "id IN ($placeholders)",
            ids.toTypedArray(),
        )
    }

    fun deleteAll() {
        helper.writableDatabase.delete(GeoDatabase.TABLE, null, null)
    }

    fun count(): Int = helper.readableDatabase
        .rawQuery("SELECT COUNT(*) FROM ${GeoDatabase.TABLE}", null)
        .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    fun deleteOlderThan(cutoffMillis: Long) {
        helper.writableDatabase.delete(
            GeoDatabase.TABLE,
            "recorded_at_millis < ?",
            arrayOf(cutoffMillis.toString()),
        )
    }

    /**
     * Keeps the newest [keep] points and drops the rest, oldest first. A long
     * offline stretch must not grow the database without bound.
     */
    fun trimTo(keep: Int) {
        helper.writableDatabase.execSQL(
            "DELETE FROM ${GeoDatabase.TABLE} WHERE id NOT IN (" +
                "SELECT id FROM ${GeoDatabase.TABLE} " +
                "ORDER BY recorded_at_millis DESC LIMIT ?)",
            arrayOf<Any>(keep),
        )
    }

    private fun Cursor.readAll(): List<PointRow> {
        val rows = mutableListOf<PointRow>()
        while (moveToNext()) {
            rows += PointRow(
                id = getString(getColumnIndexOrThrow("id")),
                lat = getDouble(getColumnIndexOrThrow("lat")),
                lon = getDouble(getColumnIndexOrThrow("lon")),
                accuracy = getDouble(getColumnIndexOrThrow("accuracy")),
                altitude = nullableDouble("altitude"),
                speed = nullableDouble("speed"),
                heading = nullableDouble("heading"),
                recordedAtMillis = getLong(
                    getColumnIndexOrThrow("recorded_at_millis"),
                ),
                isMock = getInt(getColumnIndexOrThrow("is_mock")) == 1,
                batteryLevel = nullableDouble("battery_level"),
            )
        }
        return rows
    }

    private fun Cursor.nullableDouble(column: String): Double? {
        val index = getColumnIndexOrThrow(column)
        return if (isNull(index)) null else getDouble(index)
    }
}
