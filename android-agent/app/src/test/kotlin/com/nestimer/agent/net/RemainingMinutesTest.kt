package com.nestimer.agent.net

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class RemainingMinutesTest {

    @Test
    fun `no limit when screen time is disabled`() {
        val config = AgentConfigDto(screenTimeEnabled = false, screenTimeLimitMinutes = 120)
        assertNull(config.remainingMinutes)
    }

    @Test
    fun `remaining is the shared budget minus the child's total`() {
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 30.0,
        )
        assertEquals(90.0, config.remainingMinutes!!, 0.001)
    }

    @Test
    fun `a tighter per-device cap binds instead of the shared budget`() {
        // 90 left of the shared budget, but only 20 left of this device's own 60.
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 30.0,
            deviceUsedMinutes = 40.0,
            deviceCapMinutes = 60,
        )
        assertEquals(20.0, config.remainingMinutes!!, 0.001)
    }

    @Test
    fun `remaining never goes below zero`() {
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 200.0,
        )
        assertEquals(0.0, config.remainingMinutes!!, 0.001)
    }
}
