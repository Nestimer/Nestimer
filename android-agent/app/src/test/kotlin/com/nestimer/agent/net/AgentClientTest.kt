package com.nestimer.agent.net

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

class AgentClientTest {

    private lateinit var server: MockWebServer

    @BeforeEach
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach
    fun tearDown() {
        server.shutdown()
    }

    private fun client() = AgentClient(server.url("/").toString(), "test-token")

    @Test
    fun `postUsage sends the bearer token, the date and an absolute total`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))

        val ok = client().postUsage("2026-09-12", 42.5)

        assertTrue(ok)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/agent/usage", request.path)
        assertEquals("Bearer test-token", request.getHeader("Authorization"))
        val body = request.body.readUtf8()
        assertTrue(body.contains("\"date\":\"2026-09-12\""), body)
        assertTrue(body.contains("42.5"), body)
    }

    @Test
    fun `fetchConfig sends the local date and the version, and parses the response`() {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """
                {"downtime_enabled":true,"downtime_start":"22:00","downtime_end":"08:00",
                 "screen_time_enabled":true,"screen_time_limit_minutes":120,
                 "used_minutes_today":35.5,"device_used_minutes":10.0,
                 "device_cap_minutes":60,"activities":[],"bonus_until":null}
                """.trimIndent()
            )
        )

        val config = client().fetchConfig("2026-09-12", "1.0")

        assertNotNull(config)
        assertEquals(120, config!!.screenTimeLimitMinutes)
        assertEquals(35.5, config.usedMinutesToday, 0.001)
        assertEquals(60, config.deviceCapMinutes)
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertTrue(request.path!!.startsWith("/agent/config"), request.path!!)
        assertTrue(request.path!!.contains("date=2026-09-12"), request.path!!)
        assertTrue(request.path!!.contains("version=1.0"), request.path!!)
    }

    @Test
    fun `a response omitting every optional field parses instead of throwing`() {
        // The Mac agent has the same test for the same reason: a decoder that throws
        // leaves the device with no config at all. Here it would merely stop the
        // notification updating, but the failure mode is not worth inheriting.
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"downtime_enabled":false,"downtime_start":"22:00","downtime_end":"08:00",
                    "screen_time_enabled":true,"screen_time_limit_minutes":90,
                    "used_minutes_today":5.0}"""
            )
        )

        val config = client().fetchConfig("2026-09-12", "1.0")

        assertNotNull(config)
        assertEquals(0.0, config!!.deviceUsedMinutes, 0.001)
        assertNull(config.deviceCapMinutes)
    }

    @Test
    fun `an unknown field does not break parsing`() {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"downtime_enabled":false,"downtime_start":"22:00","downtime_end":"08:00",
                    "screen_time_enabled":true,"screen_time_limit_minutes":90,
                    "used_minutes_today":5.0,"a_field_added_next_year":123}"""
            )
        )

        assertNotNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `a server error returns null rather than throwing`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `a rejected token returns null rather than throwing`() {
        server.enqueue(MockResponse().setResponseCode(401))
        assertNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `postUsage reports failure on a server error instead of throwing`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(false, client().postUsage("2026-09-12", 1.0))
    }

    @Test
    fun `a base URL with a trailing slash does not produce a double slash`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))
        AgentClient(server.url("/").toString().trimEnd('/') + "/", "t").postUsage("2026-09-12", 1.0)
        assertEquals("/agent/usage", server.takeRequest().path)
    }
}
