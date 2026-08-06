package school.attractor.attractor_geo

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import school.attractor.attractor_geo.db.PointRow
import school.attractor.attractor_geo.upload.PointJson

class PointJsonTest {
    private fun row(
        id: String = "b7e4",
        altitude: Double? = 156.0,
        speed: Double? = 4.2,
        heading: Double? = 271.0,
        batteryLevel: Double? = 0.62,
    ) = PointRow(
        id = id,
        lat = 55.751244,
        lon = 37.618423,
        accuracy = 8.5,
        altitude = altitude,
        speed = speed,
        heading = heading,
        recordedAtMillis = 1785665703000L,
        isMock = false,
        batteryLevel = batteryLevel,
    )

    @Test
    fun `encodes the wire field names`() {
        val json = PointJson.encodeOne(row())

        assertEquals("b7e4", json.getString("id"))
        assertEquals(55.751244, json.getDouble("lat"), 1e-9)
        assertEquals(37.618423, json.getDouble("lon"), 1e-9)
        assertEquals(8.5, json.getDouble("accuracy"), 1e-9)
        assertEquals(156.0, json.getDouble("altitude"), 1e-9)
        assertEquals(4.2, json.getDouble("speed"), 1e-9)
        assertEquals(271.0, json.getDouble("heading"), 1e-9)
        assertEquals(false, json.getBoolean("is_mock"))
        assertEquals(0.62, json.getDouble("battery_level"), 1e-9)
    }

    @Test
    fun `encodes recorded_at as ISO 8601 UTC with a Z suffix`() {
        assertEquals(
            "2026-08-02T10:15:03Z",
            PointJson.encodeOne(row()).getString("recorded_at"),
        )
    }

    @Test
    fun `absent sensor values are present as JSON null, not omitted`() {
        val json = PointJson.encodeOne(
            row(
                altitude = null,
                speed = null,
                heading = null,
                batteryLevel = null,
            ),
        )

        assertTrue(json.has("altitude"))
        assertTrue(json.isNull("altitude"))
        assertTrue(json.isNull("speed"))
        assertTrue(json.isNull("heading"))
        assertTrue(json.isNull("battery_level"))
    }

    @Test
    fun `a batch encodes as a flat array`() {
        val body = PointJson.encode(listOf(row(id = "a"), row(id = "b")))
        val array = JSONArray(body)

        assertEquals(2, array.length())
        assertEquals("a", array.getJSONObject(0).getString("id"))
        assertEquals("b", array.getJSONObject(1).getString("id"))
    }
}
