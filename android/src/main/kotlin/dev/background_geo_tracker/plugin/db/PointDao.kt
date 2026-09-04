package dev.background_geo_tracker.plugin.db

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteOpenHelper

/** Every SQL statement the queue needs, and nothing else. */
class PointDao(private val helper: SQLiteOpenHelper) {

    fun insert(point: PointRow) {
        val values = ContentValues().apply {
            put("id", point.id)
            put("session_id", point.sessionId)
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

    /**
     * The oldest points that are due, oldest first.
     *
     * The deferral filter is not an optimisation. Both uploaders drain in a
     * loop until this returns empty, so a stood-down batch that kept coming
     * back would spin that loop forever on the same rows.
     */
    fun oldest(limit: Int, nowMillis: Long): List<PointRow> {
        val cursor = helper.readableDatabase.rawQuery(
            "SELECT * FROM ${GeoDatabase.TABLE} " +
                "WHERE deferred_until_millis <= ? " +
                "ORDER BY recorded_at_millis ASC LIMIT ?",
            arrayOf(nowMillis.toString(), limit.toString()),
        )
        return cursor.use { it.readAll() }
    }

    fun oldestForSession(sessionId: String, limit: Int): List<PointRow> {
        val nowMillis = System.currentTimeMillis()
        val cursor = helper.readableDatabase.rawQuery(
            "SELECT * FROM ${GeoDatabase.TABLE} " +
                "WHERE session_id = ? AND deferred_until_millis <= ? " +
                "ORDER BY recorded_at_millis ASC LIMIT ?",
            arrayOf(sessionId, nowMillis.toString(), limit.toString()),
        )
        return cursor.use { it.readAll() }
    }

    fun countForSession(sessionId: String): Int = helper.readableDatabase
        .rawQuery(
            "SELECT COUNT(*) FROM ${GeoDatabase.TABLE} WHERE session_id = ?",
            arrayOf(sessionId),
        )
        .use { if (it.moveToFirst()) it.getInt(0) else 0 }

    /**
     * Stands the given points down until [untilMillis].
     *
     * Overwrites rather than accumulates: a batch refused twice waits one
     * window from the second refusal, not two from the first.
     */
    fun defer(ids: List<String>, untilMillis: Long) {
        if (ids.isEmpty()) return
        val placeholders = ids.joinToString(",") { "?" }
        val values = ContentValues().apply {
            put("deferred_until_millis", untilMillis)
        }
        helper.writableDatabase.update(
            GeoDatabase.TABLE,
            values,
            "id IN ($placeholders)",
            ids.toTypedArray(),
        )
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
                sessionId = getString(getColumnIndexOrThrow("session_id")),
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