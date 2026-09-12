package com.nestimer.agent.data

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PairingParseTest {

    @Test
    fun `parses the same string the Mac agent accepts`() {
        val p = Pairing.parse("https://my.nestimer.com|eyJhbGciOi.abc.def")
        assertEquals("https://my.nestimer.com", p!!.server)
        assertEquals("eyJhbGciOi.abc.def", p.token)
    }

    @Test
    fun `trims surrounding whitespace from a pasted string`() {
        val p = Pairing.parse("  https://my.nestimer.com | token123  ")
        assertEquals("https://my.nestimer.com", p!!.server)
        assertEquals("token123", p.token)
    }

    @Test
    fun `strips a trailing slash so URLs never double up`() {
        assertEquals("https://my.nestimer.com", Pairing.parse("https://my.nestimer.com/|t")!!.server)
    }

    @Test
    fun `a bare token with no separator is rejected`() {
        // This is exactly what the parent app used to show, and what the Mac agent
        // rejected — the reason PR #3 existed. Fail loudly rather than half-pair.
        assertNull(Pairing.parse("eyJhbGciOi.abc.def"))
    }

    @Test
    fun `more than one separator is rejected`() {
        assertNull(Pairing.parse("https://a|b|c"))
    }

    @Test
    fun `an empty half is rejected`() {
        assertNull(Pairing.parse("https://my.nestimer.com|"))
        assertNull(Pairing.parse("|token"))
    }

    @Test
    fun `a server with no scheme is rejected`() {
        // A parent who pastes "my.nestimer.com" without "https://" would otherwise save
        // cleanly and then crash-loop CountingService once a minute, forever.
        assertNull(Pairing.parse("my.nestimer.com|token"))
    }

    @Test
    fun `a server with an unsupported scheme is rejected`() {
        assertNull(Pairing.parse("ftp://my.nestimer.com|token"))
    }

    @Test
    fun `an http scheme is accepted, matching the Mac agent's dev fallback`() {
        val p = Pairing.parse("http://192.168.1.5:8000|token")
        assertEquals("http://192.168.1.5:8000", p!!.server)
    }
}
