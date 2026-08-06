import Foundation

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
}
