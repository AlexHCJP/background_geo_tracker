package school.attractor.attractor_geo.log

/**
 * One line the tracker wrote. [id] is monotonic and is also the drain cursor:
 * the reader acknowledges up to an id, and anything written after it survives.
 */
data class GeoLogRow(
    val id: Long,
    val atMillis: Long,
    val level: String,
    val event: String,
    val message: String,
)
