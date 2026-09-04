package dev.background_geo_tracker.plugin.log

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * The log's own database, in its own file.
 *
 * Deliberately not a table in `GeoDatabase`. That one's `onUpgrade` drops the
 * points table and rebuilds it, so adding a table there would mean either
 * wiping every updating user's queue or hand-writing a migration — risking
 * user data for the sake of somewhere to keep debug strings. A separate file
 * needs no migration at all, cannot grow into the queue's space, and cannot
 * take the queue down with it if it is corrupted.
 */
class GeoLogDatabase private constructor(context: Context, name: String?) :
    SQLiteOpenHelper(context, name, null, VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $TABLE (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                at_millis INTEGER NOT NULL,
                level     TEXT    NOT NULL,
                event     TEXT    NOT NULL,
                message   TEXT    NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX idx_${TABLE}_at ON $TABLE (at_millis)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Diagnostics, not user data. Rebuilding beats migrating.
        db.execSQL("DROP TABLE IF EXISTS $TABLE")
        onCreate(db)
    }

    fun store(): GeoLogStore = GeoLogStore(this)

    companion object {
        const val TABLE = "geo_log"
        private const val VERSION = 1
        private const val FILE_NAME = "background_geo_tracker_log.db"

        @Volatile
        private var instance: GeoLogDatabase? = null

        fun open(context: Context): GeoLogDatabase =
            instance ?: synchronized(this) {
                instance ?: GeoLogDatabase(context.applicationContext, FILE_NAME)
                    .also { instance = it }
            }

        /** A throwaway in-memory database, for tests. */
        fun inMemory(context: Context): GeoLogDatabase =
            GeoLogDatabase(context, null)
    }
}
