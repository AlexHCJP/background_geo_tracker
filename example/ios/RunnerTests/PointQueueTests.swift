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

    private func row(_ id: String, at millis: Int64) -> GeoPointRow {
        GeoPointRow(
            id: id,
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

        XCTAssertEqual(queue.oldest(limit: 10).map(\.id), ["a", "b", "c"])
    }

    func testOldestRespectsBatchLimit() {
        for index in 0..<5 {
            queue.enqueue(
                row("p\(index)", at: now + Int64(index)),
                maxPoints: 100,
                maxAgeDays: 7
            )
        }

        XCTAssertEqual(queue.oldest(limit: 2).count, 2)
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

        XCTAssertEqual(queue.oldest(limit: 10).map(\.id), ["p2"])
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
        XCTAssertEqual(queue.oldest(limit: 10).map(\.id), ["p2", "p3", "p4"])
    }

    func testAgeCeilingDropsPointsOlderThanWindow() {
        queue.enqueue(
            row("stale", at: now - 8 * day), maxPoints: 100, maxAgeDays: 7
        )
        queue.enqueue(row("fresh", at: now), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.oldest(limit: 10).map(\.id), ["fresh"])
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
        XCTAssertTrue(queue.oldest(limit: 10).isEmpty)
    }

    func testQueueIsUsableAfterBeingCleared() {
        queue.enqueue(row("old", at: now), maxPoints: 100, maxAgeDays: 7)
        queue.clear()
        queue.enqueue(row("new", at: now + 1), maxPoints: 100, maxAgeDays: 7)

        XCTAssertEqual(queue.oldest(limit: 10).map(\.id), ["new"])
    }

    func testNullableSensorColumnsRoundTripAsNil() {
        queue.enqueue(row("p", at: now), maxPoints: 100, maxAgeDays: 7)

        let stored = queue.oldest(limit: 1).first

        XCTAssertNil(stored?.altitude)
        XCTAssertNil(stored?.speed)
        XCTAssertNil(stored?.heading)
        XCTAssertNil(stored?.batteryLevel)
        XCTAssertEqual(stored?.lat, 55.75)
    }
}
