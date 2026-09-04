package school.attractor.attractor_geo.db

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * The point queue's storage. Plain SQLite rather than Room: the schema is one
 * table and six queries, which is not worth an annotation processor and the
 * Kotlin/KSP/AGP version matrix that comes with it.
 */
class GeoDatabase private constructor(context: Context, name: String?) :
    SQLiteOpenHelper(context, name, null, VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $TABLE (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                accuracy REAL NOT NULL,
                altitude REAL,
                speed REAL,
                heading REAL,
                recorded_at_millis INTEGER NOT NULL,
                is_mock INTEGER NOT NULL,
                battery_level REAL,
                deferred_until_millis INTEGER NOT NULL DEFAULT 0
            )
            """.trimIndent(),
        )
        db.execSQL(
            "CREATE INDEX idx_${TABLE}_recorded_at " +
                "ON $TABLE (recorded_at_millis)",
        )
    }

    /**
     * Additive, deliberately.
     *
     * This used to drop the table and rebuild it, on the reasoning that queued
     * points are disposable telemetry. That is true of their *value* and false
     * of the moment it happens: the drop lands on the launch right after an
     * update, taking whatever the user collected offline with it, for no
     * better reason than that a column was added. Every migration from here on
     * adds what it needs and leaves the rows alone.
     */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL(
                "ALTER TABLE $TABLE ADD COLUMN " +
                    "deferred_until_millis INTEGER NOT NULL DEFAULT 0",
            )
        }
    }

    fun points(): PointDao = PointDao(this)

    companion object {
        const val TABLE = "points"
        private const val VERSION = 2
        private const val FILE_NAME = "attractor_geo.db"

        @Volatile
        private var instance: GeoDatabase? = null

        fun open(context: Context): GeoDatabase =
            instance ?: synchronized(this) {
                instance ?: GeoDatabase(context.applicationContext, FILE_NAME)
                    .also { instance = it }
            }

        /** A throwaway in-memory database, for tests. */
        fun inMemory(context: Context): GeoDatabase =
            GeoDatabase(context, null)

        /**
         * A file-backed database under a name of the caller's choosing.
         *
         * For tests that need an upgrade to actually happen: [inMemory] is
         * created fresh at the current version every time and so never calls
         * [onUpgrade] at all.
         */
        fun named(context: Context, name: String): GeoDatabase =
            GeoDatabase(context, name)
    }
}
