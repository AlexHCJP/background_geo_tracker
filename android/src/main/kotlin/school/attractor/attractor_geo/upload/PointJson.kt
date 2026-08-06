package school.attractor.attractor_geo.upload

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import org.json.JSONArray
import org.json.JSONObject
import school.attractor.attractor_geo.db.PointRow

/** Builds the upload body. The wire format is fixed by the design spec. */
object PointJson {
    private val iso8601: SimpleDateFormat
        get() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

    fun encode(points: List<PointRow>): String {
        val array = JSONArray()
        points.forEach { array.put(encodeOne(it)) }
        return array.toString()
    }

    fun timestamp(millis: Long): String = iso8601.format(Date(millis))

    fun encodeOne(point: PointRow): JSONObject = JSONObject().apply {
        put("id", point.id)
        put("lat", point.lat)
        put("lon", point.lon)
        put("accuracy", point.accuracy)
        // `put(null)` removes a key, so absent sensors go in as JSONObject.NULL
        // to keep the key present with a null value, as the spec requires.
        put("altitude", point.altitude ?: JSONObject.NULL)
        put("speed", point.speed ?: JSONObject.NULL)
        put("heading", point.heading ?: JSONObject.NULL)
        put("recorded_at", timestamp(point.recordedAtMillis))
        put("is_mock", point.isMock)
        put("battery_level", point.batteryLevel ?: JSONObject.NULL)
    }
}
