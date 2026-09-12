package com.nestimer.agent.counting

object UsageCounter {

    /**
     * Foreground minutes within [startOfDayMillis, nowMillis].
     *
     * Foreground is a single timeline, not a per-package sum. When one app hands off to
     * another the two sessions overlap for a moment, and adding them would count that
     * moment twice — so sessions are unioned before they are measured.
     *
     * This is recomputed from scratch on every tick. The app keeps no running tally, so
     * there is nothing to lose when the process dies and nothing to reconcile against
     * the server's total.
     *
     * The launcher and the system UI count too, because the screen is genuinely in use
     * while they are foreground. Filtering them would need a package allowlist that
     * drifts with every OEM and Android release, and would quietly under-count.
     */
    fun foregroundMinutes(
        events: List<UsageEventRecord>,
        startOfDayMillis: Long,
        nowMillis: Long,
    ): Double {
        if (nowMillis <= startOfDayMillis) return 0.0
        val millis = merge(sessions(events, startOfDayMillis, nowMillis))
            .sumOf { (start, end) -> end - start }
        return millis / 60_000.0
    }

    /**
     * Pair each RESUMED with that package's next PAUSED.
     *
     * An unmatched RESUMED means the app is in the foreground right now, so its session
     * runs to [nowMillis]. An unmatched PAUSED means the session opened before the
     * window did — before local midnight — so it runs from [startOfDayMillis].
     */
    private fun sessions(
        events: List<UsageEventRecord>,
        startOfDayMillis: Long,
        nowMillis: Long,
    ): List<Pair<Long, Long>> {
        val ordered = events
            .map { it.copy(timestampMillis = it.timestampMillis.coerceIn(startOfDayMillis, nowMillis)) }
            .sortedBy { it.timestampMillis }

        val out = mutableListOf<Pair<Long, Long>>()
        val open = mutableMapOf<String, Long>()

        for (event in ordered) {
            when (event.type) {
                // A second RESUMED with no PAUSED between keeps the earlier start.
                EventType.RESUMED -> open.putIfAbsent(event.packageName, event.timestampMillis)
                EventType.PAUSED -> {
                    val start = open.remove(event.packageName) ?: startOfDayMillis
                    if (event.timestampMillis > start) out += start to event.timestampMillis
                }
            }
        }
        for (start in open.values) {
            if (nowMillis > start) out += start to nowMillis
        }
        return out
    }

    private fun merge(intervals: List<Pair<Long, Long>>): List<Pair<Long, Long>> {
        if (intervals.isEmpty()) return emptyList()
        val sorted = intervals.sortedBy { it.first }
        val out = mutableListOf(sorted.first())
        for ((start, end) in sorted.drop(1)) {
            val (lastStart, lastEnd) = out.last()
            if (start <= lastEnd) out[out.lastIndex] = lastStart to maxOf(lastEnd, end)
            else out += start to end
        }
        return out
    }
}
