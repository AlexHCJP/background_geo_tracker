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
        db.execSQL(
            "CREATE INDEX idx_${TABLE}_recorded_at " +
                "ON $TABLE (recorded_at_millis)",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Queued points are disposable telemetry, not user data. Rebuilding is
        // cheaper and safer than migrating.
        db.execSQL("DROP TABLE IF EXISTS $TABLE")
        onCreate(db)
    }

    fun points(): PointDao = PointDao(this)

    companion object {
        const val TABLE = "points"
        private const val VERSION = 1
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
    }
}
