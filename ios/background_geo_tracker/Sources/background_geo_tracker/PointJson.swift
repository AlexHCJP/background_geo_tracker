import Foundation

/// Builds the upload body. The wire format is fixed by the design spec.
enum PointJson {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func timestamp(_ millis: Int64) -> String {
        formatter.string(
            from: Date(timeIntervalSince1970: Double(millis) / 1000)
        )
    }

    static func encodeOne(_ row: GeoPointRow) -> [String: Any] {
        // NSNull, not a dropped key: the spec requires the key to be present
        // with a null value when a sensor has nothing to report.
        [
            "id": row.id,
            "session_id": row.sessionId,
            "lat": row.lat,
            "lon": row.lon,
            "accuracy": row.accuracy,
            "altitude": row.altitude ?? NSNull(),
            "speed": row.speed ?? NSNull(),
            "heading": row.heading ?? NSNull(),
            "recorded_at": timestamp(row.recordedAtMillis),
            "is_mock": row.isMock,
            "battery_level": row.batteryLevel ?? NSNull(),
        ]
    }

    static func encode(_ rows: [GeoPointRow]) -> Data {
        let payload = rows.map(encodeOne)
        return (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data("[]".utf8)
    }
}
