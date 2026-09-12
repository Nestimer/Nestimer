package com.nestimer.agent.counting

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

private const val DAY_START = 1_757_635_200_000L // arbitrary local midnight
private fun min(n: Long) = DAY_START + n * 60_000L

private fun resumed(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.RESUMED, min(atMinute))

private fun paused(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.PAUSED, min(atMinute))

private fun allStopped(atMinute: Long) = UsageEventRecord.allStopped(min(atMinute))

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

    @Test
    fun `a shutdown closes an open session instead of running it to now`() {
        // The worked example in miniature: YouTube open at 09:00 (minute 540), phone
        // powers off at 09:05 (545), boots at 13:00 (780). Android emits no PAUSED for
        // YouTube — ever — so without ALL_STOPPED this is ~240 minutes of foreground
        // time for a phone that was switched off, re-reported every tick until midnight.
        val events = listOf(
            resumed("com.youtube", 540),
            allStopped(545),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(780))
        assertEquals(5.0, total, 0.001)
    }

    @Test
    fun `a shutdown and a startup count the two real sessions, not the gap between them`() {
        val events = listOf(
            resumed("com.youtube", 540),
            allStopped(545),  // DEVICE_SHUTDOWN
            allStopped(780),  // DEVICE_STARTUP — nothing open, so a no-op
            resumed("com.chrome", 790),
            paused("com.chrome", 800),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(900))
        assertEquals(15.0, total, 0.001) // 5 + 10; the 235-minute power-off is not usage
    }

    @Test
    fun `a startup with nothing open does not invent a session from the start of the day`() {
        // A close must never behave like an unmatched PAUSED. If it did, the first boot
        // of the day would post the whole morning as used.
        val total = UsageCounter.foregroundMinutes(listOf(allStopped(300)), DAY_START, min(600))
        assertEquals(0.0, total, 0.001)
    }

    @Test
    fun `the screen going non-interactive closes an open session`() {
        val events = listOf(
            resumed("com.chrome", 10),
            allStopped(25), // SCREEN_NON_INTERACTIVE
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(15.0, total, 0.001)
    }

    @Test
    fun `a shutdown closes every open session, not just the last one`() {
        val events = listOf(
            resumed("com.chrome", 10),
            resumed("com.youtube", 28),
            paused("com.chrome", 30),
            allStopped(50),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(40.0, total, 0.001) // one merged timeline, 10..50
    }

    @Test
    fun `in-app navigation is not cut short by the outgoing activity's ACTIVITY_STOPPED`() {
        // This is the regression the STOPPED-handling removal protects against. Ordinary
        // navigation between two activities of the *same* app emits, all under one
        // packageName: ACTIVITY_PAUSED(A1), ACTIVITY_RESUMED(A2), ACTIVITY_STOPPED(A1).
        // Sessions here are keyed by packageName alone, with no per-activity identity, so
        // a STOPPED for A1 could only ever remove the entry that actually belongs to the
        // still-foreground A2 session. If that STOPPED were honoured, A2's real PAUSED at
        // 10:00 would find nothing open and fall back to startOfDayMillis, turning 60
        // minutes of real use into 600. EventReader now drops ACTIVITY_STOPPED before it
        // ever becomes a UsageEventRecord (see EventReader.typeOf), so it is deliberately
        // absent from this list too, exactly as it reaches UsageCounter in production.
        val events = listOf(
            resumed("com.example.app", 540), // A1 resumes at 09:00
            paused("com.example.app", 541),  // A1 pauses at 09:01
            resumed("com.example.app", 541), // A2 resumes at 09:01
            // ACTIVITY_STOPPED(A1) fires here in the real event stream but never reaches
            // UsageCounter as a UsageEventRecord — it is filtered out upstream.
            paused("com.example.app", 600),  // A2 pauses at 10:00
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(60.0, total, 0.001)
    }
}
