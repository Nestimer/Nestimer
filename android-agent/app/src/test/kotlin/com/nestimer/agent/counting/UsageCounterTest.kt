package com.nestimer.agent.counting

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

private const val DAY_START = 1_757_635_200_000L // arbitrary local midnight
private fun min(n: Long) = DAY_START + n * 60_000L

private fun resumed(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.RESUMED, min(atMinute))

private fun paused(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.PAUSED, min(atMinute))

class UsageCounterTest {

    @Test
    fun `no events is zero, not a crash`() {
        val total = UsageCounter.foregroundMinutes(emptyList(), DAY_START, min(600))
        assertEquals(0.0, total, 0.001)
    }

    @Test
    fun `a single resume-pause pair counts its length`() {
        val events = listOf(resumed("com.chrome", 10), paused("com.chrome", 25))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(15.0, total, 0.001)
    }

    @Test
    fun `an app still in the foreground counts up to now, not to zero`() {
        val events = listOf(resumed("com.chrome", 10))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(40))
        assertEquals(30.0, total, 0.001)
    }

    @Test
    fun `a pause with no resume counts from the start of the day`() {
        // The session began before local midnight, so queryEvents never returns its
        // RESUMED. Counting from zero would silently lose the morning.
        val events = listOf(paused("com.chrome", 20))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(20.0, total, 0.001)
    }

    @Test
    fun `a handoff between apps is one timeline, not two sessions added up`() {
        // Chrome 10..30, YouTube 28..50. Overlap is 28..30. Summing per package
        // gives 20 + 22 = 42; the truth is 10..50 = 40.
        val events = listOf(
            resumed("com.chrome", 10),
            resumed("com.youtube", 28),
            paused("com.chrome", 30),
            paused("com.youtube", 50),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(40.0, total, 0.001)
    }

    @Test
    fun `two separate sessions with a gap are both counted`() {
        val events = listOf(
            resumed("com.chrome", 10), paused("com.chrome", 20),
            resumed("com.chrome", 100), paused("com.chrome", 115),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(25.0, total, 0.001) // 10 + 15; the 80-minute gap is not usage
    }

    @Test
    fun `events out of order are handled - the API does not guarantee ordering`() {
        val events = listOf(
            paused("com.chrome", 20),
            resumed("com.chrome", 10),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(10.0, total, 0.001)
    }

    @Test
    fun `a repeated resume with no pause between keeps the earlier start`() {
        val events = listOf(
            resumed("com.chrome", 10),
            resumed("com.chrome", 15),
            paused("com.chrome", 25),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(15.0, total, 0.001)
    }

    @Test
    fun `timestamps outside the window are clamped into it`() {
        val before = UsageEventRecord("com.chrome", EventType.RESUMED, DAY_START - 3_600_000L)
        val events = listOf(before, paused("com.chrome", 20))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(20.0, total, 0.001)
    }

    @Test
    fun `now before the start of the day is zero, not negative`() {
        val events = listOf(resumed("com.chrome", 10))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, DAY_START - 1000)
        assertEquals(0.0, total, 0.001)
    }
}
