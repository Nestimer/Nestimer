package com.nestimer.agent.service

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import com.nestimer.agent.counting.EventType
import com.nestimer.agent.counting.UsageEventRecord

/**
 * The whole Android-specific part of counting: turn the platform's event stream into
 * the framework-free records `UsageCounter` understands.
 *
 * This history lives in the system, not in this process, which is why the counter can
 * be stateless and why a force-stop costs the child only the window the app was dead.
 */
class EventReader(private val context: Context) {

    fun eventsBetween(startMillis: Long, endMillis: Long): List<UsageEventRecord> {
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val stream = manager.queryEvents(startMillis, endMillis)
        val out = mutableListOf<UsageEventRecord>()
        val event = UsageEvents.Event()
        while (stream.hasNextEvent()) {
            stream.getNextEvent(event)
            val type = when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> EventType.RESUMED
                UsageEvents.Event.ACTIVITY_PAUSED -> EventType.PAUSED
                else -> null
            }
            if (type != null) {
                out += UsageEventRecord(event.packageName ?: continue, type, event.timeStamp)
            }
        }
        return out
    }
}
