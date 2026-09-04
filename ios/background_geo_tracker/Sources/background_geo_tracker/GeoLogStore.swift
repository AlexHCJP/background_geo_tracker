import Foundation
import SQLite3

/// One line the tracker wrote. `id` is monotonic and is also the drain cursor:
/// the reader acknowledges up to an id, and anything written after it survives.
struct GeoLogRow {
    let id: Int64
    let atMillis: Int64
    let level: String
    let event: String
    let message: String
}

/// The log's storage, in its own database file.
///
/// Deliberately not a table inside `PointStore`. That type holds a single
/// connection on purpose — its own comment warns that two independent
/// connections to one file hand the overlap between a write and a delete to
/// SQLite's file locking and lose writes to `SQLITE_BUSY` — so a log living
/// there would have to either be built into `PointStore`, giving it a second
/// responsibility, or force the shared connection out into a third type. Its
/// own file needs neither, and keeps a corrupt log from taking the queue with
/// it.
///
/// Must stay behaviourally identical to the Kotlin `GeoLogStore`.
final class GeoLogStore {
    /// Roughly five hours of walking at the collector's current settings.
    static let maxRows = 2000
    static let maxAgeDays: Int64 = 3
    private static let dayMillis: Int64 = 86_400_000

    static let inMemoryPath = ":memory:"

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// SQLite must copy the text rather than reference our buffer, which is
    /// gone by the time `step` runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    /// The one log everything writes to.
    static let shared: GeoLogStore? = GeoLogStore(path: defaultPath())

    /// Alongside the queue, in the app's support directory.
    static func defaultPath() -> String {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("background_geo_tracker_log.sqlite").path
    }

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 3000)
        guard exec(
            """
            CREATE TABLE IF NOT EXISTS geo_log (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                at_millis INTEGER NOT NULL,
                level     TEXT    NOT NULL,
                event     TEXT    NOT NULL,
                message   TEXT    NOT NULL
            )
            """
        ) else { return nil }
        exec("CREATE INDEX IF NOT EXISTS idx_geo_log_at ON geo_log (at_millis)")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func write(atMillis: Int64, level: String, event: String, message: String) {
        lock.lock()
        var statement: OpaquePointer?
        let sql = "INSERT INTO geo_log (at_millis, level, event, message) "
            + "VALUES (?, ?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, atMillis)
            sqlite3_bind_text(statement, 2, level, -1, Self.transient)
            sqlite3_bind_text(statement, 3, event, -1, Self.transient)
            sqlite3_bind_text(statement, 4, message, -1, Self.transient)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        lock.unlock()

        // The cutoff is measured from the incoming entry rather than the wall
        // clock, so a device whose clock jumped cannot wipe a valid log.
        deleteOlderThan(atMillis - Self.maxAgeDays * Self.dayMillis)
        if count() > Self.maxRows { trim(to: Self.maxRows) }
    }

    /// Oldest first, by id rather than by timestamp.
    ///
    /// The log records the order things happened in. A fix whose clock
    /// disagrees with its neighbours is itself worth seeing where it arrived,
    /// not sorted into a position that hides the disagreement.
    func read(limit: Int) -> [GeoLogRow] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let sql = "SELECT id, at_millis, level, event, message FROM geo_log "
            + "ORDER BY id ASC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [GeoLogRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let level = sqlite3_column_text(statement, 2),
                  let event = sqlite3_column_text(statement, 3),
                  let message = sqlite3_column_text(statement, 4)
            else { continue }
            rows.append(
                GeoLogRow(
                    id: sqlite3_column_int64(statement, 0),
                    atMillis: sqlite3_column_int64(statement, 1),
                    level: String(cString: level),
                    event: String(cString: event),
                    message: String(cString: message)
                )
            )
        }
        return rows
    }

    /// Acknowledges everything up to and including `untilId`.
    ///
    /// Bounded by id rather than emptying the table: entries written while the
    /// reader was busy have been seen by nobody and must survive.
    func drop(untilId: Int64) {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "DELETE FROM geo_log WHERE id <= ?", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, untilId)
        sqlite3_step(statement)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        exec("DELETE FROM geo_log")
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM geo_log", -1, &statement, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW
            ? Int(sqlite3_column_int(statement, 0))
            : 0
    }

    private func deleteOlderThan(_ cutoffMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "DELETE FROM geo_log WHERE at_millis < ?", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, cutoffMillis)
        sqlite3_step(statement)
    }

    private func trim(to keep: Int) {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let sql = "DELETE FROM geo_log WHERE id NOT IN ("
            + "SELECT id FROM geo_log ORDER BY id DESC LIMIT ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(keep))
        sqlite3_step(statement)
    }
}
