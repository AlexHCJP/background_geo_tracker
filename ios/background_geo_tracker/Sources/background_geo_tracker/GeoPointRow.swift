import CoreLocation
import Foundation
import UIKit

/// One queued fix. `id` is a locally generated UUID, so a retried batch
/// de-duplicates on the backend instead of doubling the track.
struct GeoPointRow {
    let id: String
    let lat: Double
    let lon: Double
    let accuracy: Double
    let altitude: Double?
    let speed: Double?
    let heading: Double?
    let recordedAtMillis: Int64
    let isMock: Bool
    let batteryLevel: Double?

    /// The one place a `CLLocation` becomes a point.
    ///
    /// Shared by the collector and by the one-shot read, which have to agree:
    /// a fix that arrives through `currentPosition` and the same fix arriving
    /// a moment later through the session must not differ in what they say
    /// about altitude, speed or the battery.
    static func from(_ location: CLLocation) -> GeoPointRow {
        GeoPointRow(
            id: UUID().uuidString,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            // CLLocation reports -1 when it has nothing, which must not be
            // sent on as a real reading.
            speed: location.speed >= 0 ? location.speed : nil,
            heading: location.course >= 0 ? location.course : nil,
            recordedAtMillis: Int64(
                location.timestamp.timeIntervalSince1970 * 1000
            ),
            isMock: isSimulated(location),
            batteryLevel: batteryLevel()
        )
    }

    /// The same fix, placed where the filter says the device actually is.
    ///
    /// Only the three the smoother has an opinion about. `speed`, `heading`
    /// and `isMock` stay exactly as the OS reported them: the filter models
    /// position and nothing else, and a smoothed coordinate carrying a
    /// recomputed speed would be inventing a reading rather than cleaning one.
    func movedTo(lat: Double, lon: Double, accuracy: Double) -> GeoPointRow {
        GeoPointRow(
            id: id,
            lat: lat,
            lon: lon,
            accuracy: accuracy,
            altitude: altitude,
            speed: speed,
            heading: heading,
            recordedAtMillis: recordedAtMillis,
            isMock: isMock,
            batteryLevel: batteryLevel
        )
    }

    private static func isSimulated(_ location: CLLocation) -> Bool {
        if #available(iOS 15.0, *) {
            return location.sourceInformation?.isSimulatedBySoftware ?? false
        }
        // No API below iOS 15 — reported as not simulated rather than guessed.
        return false
    }

    /// Fraction from 0.0 to 1.0, as the wire format requires.
    private static func batteryLevel() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }
}
