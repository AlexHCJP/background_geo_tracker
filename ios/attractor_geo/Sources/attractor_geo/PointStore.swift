import Foundation
import SQLite3

/// Raw sqlite3. The schema is one table and six statements, which is not
/// worth a dependency.
final class PointStore {
    static let inMemoryPath = ":memory:"

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// SQLite must copy the text rather than reference our buffer, which is
    /// gone by the time `step` runs.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        // Belt and braces: the tracker and the uploader share one connection,
        // but a relaunched process can briefly overlap with the dying one.
        // Without this, a contended write returns SQLITE_BUSY immediately.
        sqlite3_busy_timeout(db, 3000)
        let created = exec(
            """
            CREATE TABLE IF NOT EXISTS points (
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
            """
        )
        guard created else { return nil }
        exec(
            "CREATE INDEX IF NOT EXISTS idx_points_recorded_at "
                + "ON points (recorded_at_millis)"
        )
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindDouble(
        _ statement: OpaquePointer?, _ index: Int32, _ value: Double?
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    @discardableResult
    func insert(_ row: GeoPointRow) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO points
            (id, lat, lon, accuracy, altitude, speed, heading,
             recorded_at_millis, is_mock, battery_level)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, row.id, -1, Self.transient)
        sqlite3_bind_double(statement, 2, row.lat)
        sqlite3_bind_double(statement, 3, row.lon)
        sqlite3_bind_double(statement, 4, row.accuracy)
        bindDouble(statement, 5, row.altitude)
        bindDouble(statement, 6, row.speed)
        bindDouble(statement, 7, row.heading)
        sqlite3_bind_int64(statement, 8, row.recordedAtMillis)
        sqlite3_bind_int(statement, 9, row.isMock ? 1 : 0)
        bindDouble(statement, 10, row.batteryLevel)

        // A dropped write is a hole in someone's track. Never swallow it
        // silently — this is the one statement whose failure loses data.
        guard sqlite3_step(statement) == SQLITE_DONE else {
            NSLog(
                "attractor_geo: failed to queue point %@: %s",
                row.id,
                sqlite3_errmsg(db)
            )
            return false
        }
        return true
    }

    func oldest(limit: Int) -> [GeoPointRow] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let sql = "SELECT id, lat, lon, accuracy, altitude, speed, heading, "
            + "recorded_at_millis, is_mock, battery_level FROM points "
            + "ORDER BY recorded_at_millis ASC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        func double(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, index)
        }

        var rows: [GeoPointRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else {
                continue
            }
            rows.append(
                GeoPointRow(
                    id: String(cString: idText),
                    lat: sqlite3_column_double(statement, 1),
                    lon: sqlite3_column_double(statement, 2),
                    accuracy: sqlite3_column_double(statement, 3),
                    altitude: double(4),
                    speed: double(5),
                    heading: double(6),
                    recordedAtMillis: sqlite3_column_int64(statement, 7),
                    isMock: sqlite3_column_int(statement, 8) == 1,
                    batteryLevel: double(9)
                )
            )
        }
        return rows
    }

    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let placeholders = Array(repeating: "?", count: ids.count)
            .joined(separator: ",")
        var statement: OpaquePointer?
        let sql = "DELETE FROM points WHERE id IN (\(placeholders))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }

        for (offset, id) in ids.enumerated() {
            sqlite3_bind_text(
                statement, Int32(offset + 1), id, -1, Self.transient
            )
        }
        sqlite3_step(statement)
    }

    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }

        exec("DELETE FROM points")
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM points", -1, &statement, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        return sqlite3_step(statement) == SQLITE_ROW
            ? Int(sqlite3_column_int(statement, 0))
            : 0
    }

    func deleteOlderThan(_ cutoffMillis: Int64) {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM points WHERE recorded_at_millis < ?",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, cutoffMillis)
        sqlite3_step(statement)
    }

    /// Keeps the newest `keep` points and drops the rest, oldest first.
    func trim(to keep: Int) {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let sql = "DELETE FROM points WHERE id NOT IN ("
            + "SELECT id FROM points ORDER BY recorded_at_millis DESC LIMIT ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(keep))
        sqlite3_step(statement)
    }
}
