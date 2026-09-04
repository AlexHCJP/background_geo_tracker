import SQLite3
import XCTest

@testable import background_geo_tracker

final class PointQueueTests: XCTestCase {
    private var queue: PointQueue!
    private let now: Int64 = 1_785_665_703_000
    private let day: Int64 = 86_400_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        let store = try XCTUnwrap(PointStore(path: PointStore.inMemoryPath))
        queue = PointQueue(store: store)
    }

    private func row(
        _ id: String,
        at millis: Int64,
        sessionId: String = "consent-42"
    ) -> GeoPointRow {
        GeoPointRow(
            id: id,
            sessionId: sessionId,
            lat: 55.75,
            lon: 37.61,
            accuracy: 10,
            altitude: nil,
            speed: nil,
            heading: nil,
            recordedAtMillis: millis,
            isMock: false,
            batteryLevel: nil
        )
    }

    func testOldestReturnsPointsInRecordingOrder() {
        queue.enqueue(row("c", at: now + 2), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("b", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["a", "b", "c"])
    }

    func testOldestRespectsBatchLimit() {
        for index in 0..<5 {
            queue.enqueue(
                row("p\(index)", at: now + Int64(index)),
                maxPoints: 100,
                maxAgeDays: 7
            )
        }

        XCTAssertEqual(queue.oldest(limit: 2, nowMillis: now).count, 2)
    }

    func testSessionQueryNeverReturnsAnotherSessionsPoints() {
        queue.enqueue(
            row("old", at: now, sessionId: "consent-old"),
            maxPoints: 100,
            maxAgeDays: 7
        )
        queue.enqueue(
            row("new", at: now + 1, sessionId: "consent-new"),
            maxPoints: 100,
            maxAgeDays: 7
        )

        XCTAssertEqual(
            queue.oldest(sessionId: "consent-new", limit: 10).map(\.id),
            ["new"]
        )
    }

    func testDropDeletesOnlyAcknowledgedPoints() {
        for index in 0..<3 {
            queue.enqueue(
                row("p\(index)", at: now + Int64(index)),
                maxPoints: 100,
                maxAgeDays: 7
            )
        }

        queue.drop(ids: ["p0", "p1"])

        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["p2"])
    }

    func testPointCeilingEvictsOldestFirst() {
        for index in 0..<5 {
            queue.enqueue(
                row("p\(index)", at: now + Int64(index)),
                maxPoints: 3,
                maxAgeDays: 7
            )
        }

        XCTAssertEqual(queue.count(), 3)
        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["p2", "p3", "p4"])
    }

    func testAgeCeilingDropsPointsOlderThanWindow() {
        queue.enqueue(
            row("stale", at: now - 8 * day), maxPoints: 100, maxAgeDays: 7
        )
        queue.enqueue(row("fresh", at: now), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["fresh"])
    }

    func testReEnqueuingSameIdDoesNotDuplicate() {
        queue.enqueue(row("p", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("p", at: now), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.count(), 1)
    }

    func testClearEmptiesTheQueue() {
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("b", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        queue.clear()

        XCTAssertEqual(queue.count(), 0)
        XCTAssertTrue(queue.oldest(limit: 10, nowMillis: now).isEmpty)
    }

    func testQueueIsUsableAfterBeingCleared() {
        queue.enqueue(row("old", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.clear()
        queue.enqueue(row("new", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["new"])
    }

    func testNullableSensorColumnsRoundTripAsNil() {
        queue.enqueue(row("p", at: now), maxPoints: 100, maxAgeDays: 7)

        let stored = queue.oldest(limit: 1, nowMillis: now).first

        XCTAssertNil(stored?.altitude)
        XCTAssertNil(stored?.speed)
        XCTAssertNil(stored?.heading)
        XCTAssertNil(stored?.batteryLevel)
        XCTAssertEqual(stored?.lat, 55.75)
        XCTAssertEqual(stored?.sessionId, "consent-42")
    }

    // MARK: - Deferral

    func testDeferredPointIsWithheldUntilItsTimeComes() {
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)

        queue.defer(ids: ["a"], untilMillis: now + 60_000)

        XCTAssertTrue(queue.oldest(limit: 10, nowMillis: now).isEmpty)
    }

    func testDeferredPointComesBackOnceItsTimeHasPassed() {
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.defer(ids: ["a"], untilMillis: now + 60_000)

        XCTAssertEqual(
            queue.oldest(limit: 10, nowMillis: now + 60_001).map(\.id), ["a"]
        )
    }

    func testQueueMovesPastADeferredHead() {
        // The whole reason deferral exists rather than dropping: the queue is
        // read from the head, so a batch that is never accepted would
        // otherwise be re-read forever and nothing behind it would move.
        queue.enqueue(row("stuck", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("fine", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        queue.defer(ids: ["stuck"], untilMillis: now + 60_000)

        XCTAssertEqual(
            queue.oldest(limit: 10, nowMillis: now).map(\.id), ["fine"]
        )
    }

    func testDeferTouchesOnlyTheIdsItIsGiven() {
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.enqueue(row("b", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        queue.defer(ids: ["a"], untilMillis: now + 60_000)

        XCTAssertEqual(queue.oldest(limit: 10, nowMillis: now).map(\.id), ["b"])
    }

    func testASecondRefusalMovesTheWindowRatherThanStackingIt() {
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)

        queue.defer(ids: ["a"], untilMillis: now + 60_000)
        queue.defer(ids: ["a"], untilMillis: now + 10_000)

        // Overwritten, not added to: the point is due at the second deadline.
        XCTAssertEqual(
            queue.oldest(limit: 10, nowMillis: now + 10_001).map(\.id), ["a"]
        )
    }

    func testCountIncludesDeferredPoints() {
        // The status answers "how much has not arrived yet", and a deferred
        // point has not arrived.
        queue.enqueue(row("a", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.defer(ids: ["a"], untilMillis: now + 60_000)

        XCTAssertEqual(queue.count(), 1)
    }

    // MARK: - Migration

    func testAStoreBuiltBeforeTheColumnKeepsItsRows() throws {
        // The cost of getting this wrong is not a red test — it is every
        // updating user's queue, silently emptied on the launch after an
        // update.
        let path = NSTemporaryDirectory() + "legacy_points_xctest.sqlite"
        try? FileManager.default.removeItem(atPath: path)

        var raw: OpaquePointer?
        sqlite3_open(path, &raw)
        sqlite3_exec(raw, """
            CREATE TABLE points (
                id TEXT PRIMARY KEY NOT NULL, lat REAL NOT NULL,
                lon REAL NOT NULL, accuracy REAL NOT NULL, altitude REAL,
                speed REAL, heading REAL, recorded_at_millis INTEGER NOT NULL,
                is_mock INTEGER NOT NULL, battery_level REAL
            )
            """, nil, nil, nil)
        sqlite3_exec(
            raw,
            "INSERT INTO points (id, lat, lon, accuracy, recorded_at_millis, "
                + "is_mock) VALUES ('survivor', 55.75, 37.61, 10.0, "
                + "\(now), 0)",
            nil, nil, nil
        )
        sqlite3_close(raw)

        let migrated = PointQueue(store: try XCTUnwrap(PointStore(path: path)))

        XCTAssertEqual(
            migrated.oldest(limit: 10, nowMillis: now).map(\.id), ["survivor"]
        )
        // And the column is genuinely usable, not merely present.
        migrated.defer(ids: ["survivor"], untilMillis: now + 60_000)
        XCTAssertTrue(migrated.oldest(limit: 10, nowMillis: now).isEmpty)
    }
}
