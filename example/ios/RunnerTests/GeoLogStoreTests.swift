import XCTest

@testable import background_geo_tracker

/// Mirrors the Kotlin `GeoLogStoreTest` case for case. These cannot be run in
/// this project — XCTest needs a simulator — so a parity harness is what
/// actually proves them; this file exists so a machine with Xcode gets the
/// coverage for free.
final class GeoLogStoreTests: XCTestCase {

    private var store: GeoLogStore!

    override func setUp() {
        super.setUp()
        store = GeoLogStore(path: GeoLogStore.inMemoryPath)
    }

    private func write(_ atMillis: Int64, _ message: String) {
        store.write(
            atMillis: atMillis,
            level: "info",
            event: "fix.accepted",
            message: message
        )
    }

    func testEntriesComeBackInInsertionOrder() {
        write(3_000, "third")
        write(1_000, "first")
        write(2_000, "second")

        // By id, not by timestamp: the log records the order things happened
        // in, and a fix whose clock disagrees is itself worth seeing in place.
        XCTAssertEqual(
            store.read(limit: 10).map(\.message), ["third", "first", "second"]
        )
    }

    func testReadRespectsTheLimit() {
        for i in 0..<5 { write(Int64(i), "entry \(i)") }

        XCTAssertEqual(store.read(limit: 2).count, 2)
    }

    func testReadDoesNotDelete() {
        write(1_000, "kept")

        _ = store.read(limit: 10)

        XCTAssertEqual(store.count(), 1)
    }

    func testDropLeavesEntriesWrittenAfterTheRead() {
        // The whole point of the two-phase drain: anything the reader never
        // saw must survive its acknowledgement.
        write(1_000, "drained")
        let seen = store.read(limit: 10)
        write(2_000, "arrived while draining")

        store.drop(untilId: seen.last!.id)

        XCTAssertEqual(
            store.read(limit: 10).map(\.message), ["arrived while draining"]
        )
    }

    func testRowCeilingEvictsTheOldestFirst() {
        for i in 0..<(GeoLogStore.maxRows + 10) { write(Int64(i), "entry \(i)") }

        XCTAssertEqual(store.count(), GeoLogStore.maxRows)
        XCTAssertEqual(store.read(limit: 1).first?.message, "entry 10")
    }

    func testAgeCeilingDropsEntriesOlderThanTheWindow() {
        let now: Int64 = 10_000_000_000
        let window = GeoLogStore.maxAgeDays * 86_400_000
        write(now - window - 1, "ancient")

        // Measured from the incoming entry, so a clock that jumped cannot wipe
        // a valid log — the same rule the point queue uses.
        write(now, "fresh")

        XCTAssertEqual(store.read(limit: 10).map(\.message), ["fresh"])
    }

    func testClearEmptiesTheLog() {
        write(1_000, "gone")

        store.clear()

        XCTAssertTrue(store.read(limit: 10).isEmpty)
    }
}
