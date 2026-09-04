package school.attractor.attractor_geo.db

/**
 * One queued fix. [id] is a natively generated UUID and is the primary key, so
 * a retried batch de-duplicates on the backend instead of doubling the track.
 */
data class PointRow(
    val id: String,
    val sessionId: String,
    val lat: Double,
    val lon: Double,
    val accuracy: Double,
    val altitude: Double?,
    val speed: Double?,
    val heading: Double?,
    val recordedAtMillis: Long,
    val isMock: Boolean,
    val batteryLevel: Double?,
)
