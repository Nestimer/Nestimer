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
            val type = typeOf(event.eventType) ?: continue
            if (type == EventType.ALL_STOPPED) {
                // Not about any one app, and the platform attaches no useful package
                // name to these, so they skip the packageName check below.
                out += UsageEventRecord.allStopped(event.timeStamp)
            } else {
                val pkg = event.packageName
                if (pkg != null) out += UsageEventRecord(pkg, type, event.timeStamp)
            }
        }
        return out
    }

    /**
     * The only place in the app that knows the platform's event numbers.
     *
     * The closing events are not decoration. `DEVICE_SHUTDOWN` is documented to mean
     * that every started activity is now stopped and that *no* explicit per-activity
     * stop events will follow, so the app that was foreground when the phone powered
     * off never gets an `ACTIVITY_PAUSED` — on a flat battery it gets nothing at all.
     * `UsageCounter` would then run that session to now, on this tick and every later
     * one, and bill a powered-off phone to the child's shared daily budget.
     * `DEVICE_STARTUP` closes anything still open from before the boot for the same
     * reason, and `SCREEN_NON_INTERACTIVE` is cheap insurance for any other path where
     * the pause goes missing. `ACTIVITY_STOPPED` closes one package's session and is a
     * no-op in the normal RESUMED → PAUSED → STOPPED order.
     */
    private fun typeOf(eventType: Int): EventType? = when (eventType) {
        UsageEvents.Event.ACTIVITY_RESUMED -> EventType.RESUMED
        UsageEvents.Event.ACTIVITY_PAUSED -> EventType.PAUSED
        UsageEvents.Event.ACTIVITY_STOPPED -> EventType.STOPPED
        UsageEvents.Event.DEVICE_SHUTDOWN,
        UsageEvents.Event.DEVICE_STARTUP,
        UsageEvents.Event.SCREEN_NON_INTERACTIVE,
        -> EventType.ALL_STOPPED
        else -> null
    }
}
