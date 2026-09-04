import XCTest

@testable import background_geo_tracker

final class PointJsonTests: XCTestCase {
    private func row(
        id: String = "b7e4",
        altitude: Double? = 156.0,
        speed: Double? = 4.2,
        heading: Double? = 271.0,
        batteryLevel: Double? = 0.62
    ) -> GeoPointRow {
        GeoPointRow(
            id: id,
            sessionId: "consent-42",
            lat: 55.751244,
            lon: 37.618423,
            accuracy: 8.5,
            altitude: altitude,
            speed: speed,
            heading: heading,
            recordedAtMillis: 1_785_665_703_000,
            isMock: false,
            batteryLevel: batteryLevel
        )
    }

    func testEncodesWireFieldNames() {
        let json = PointJson.encodeOne(row())

        XCTAssertEqual(json["id"] as? String, "b7e4")
        XCTAssertEqual(json["session_id"] as? String, "consent-42")
        XCTAssertEqual(json["lat"] as? Double, 55.751244)
        XCTAssertEqual(json["lon"] as? Double, 37.618423)
        XCTAssertEqual(json["accuracy"] as? Double, 8.5)
        XCTAssertEqual(json["altitude"] as? Double, 156.0)
        XCTAssertEqual(json["speed"] as? Double, 4.2)
        XCTAssertEqual(json["heading"] as? Double, 271.0)
        XCTAssertEqual(json["is_mock"] as? Bool, false)
        XCTAssertEqual(json["battery_level"] as? Double, 0.62)
    }

    func testEncodesTimestampAsIso8601Utc() {
        XCTAssertEqual(
            PointJson.encodeOne(row())["recorded_at"] as? String,
            "2026-08-02T10:15:03Z"
        )
    }

    func testAbsentSensorsArePresentAsNull() {
        let json = PointJson.encodeOne(
            row(altitude: nil, speed: nil, heading: nil, batteryLevel: nil)
        )

        XCTAssertTrue(json["altitude"] is NSNull)
        XCTAssertTrue(json["speed"] is NSNull)
        XCTAssertTrue(json["heading"] is NSNull)
        XCTAssertTrue(json["battery_level"] is NSNull)
    }

    func testBatchEncodesAsFlatArray() throws {
        let data = PointJson.encode([row(id: "a"), row(id: "b")])
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["id"] as? String, "a")
        XCTAssertEqual(array[1]["id"] as? String, "b")
    }
}
